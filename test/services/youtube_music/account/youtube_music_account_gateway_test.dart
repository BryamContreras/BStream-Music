import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('authenticated account reads', () {
    test('parses profile and exact account menu endpoint', () async {
      final transport = _FakeAccountTransport(<Object>[_ok(_profileFixture())]);
      final gateway = _gateway(transport);

      final profile = await gateway.getProfile();

      expect(profile?.displayName, 'BStream User');
      expect(profile?.email, 'listener@example.test');
      expect(profile?.handle, '@bstream');
      expect(profile?.avatarUrl, 'https://img.test/avatar-large.jpg');
      expect(profile?.channelId, 'UC-profile');
      expect(transport.requests.single.endpoint, 'account/account_menu');
      expect(transport.requests.single.body['context'], _clientContext);
    });

    test('parses Google account and selectable channels', () async {
      final transport = _FakeAccountTransport(<Object>[
        _ok(_accountsFixture()),
      ]);

      final directory = await _gateway(transport).getAccounts();

      expect(directory.accounts, hasLength(1));
      expect(directory.accounts.single.email, 'listener@example.test');
      expect(directory.channels, hasLength(2));
      expect(directory.selectedChannel?.displayName, 'Main channel');
      expect(directory.selectedChannel?.pageId, 'UC-main');
      expect(directory.selectedChannel?.dataSyncId, 'UC-main||sync');
      expect(
        directory.selectedChannel?.signInUrl,
        'https://music.youtube.com/channel-switch/main',
      );
      final request = transport.requests.single;
      expect(request.endpoint, 'account/accounts_list');
      expect(
        request.body['requestType'],
        'ACCOUNTS_LIST_REQUEST_TYPE_CHANNEL_SWITCHER',
      );
      expect(request.body['callCircumstance'], 'SWITCHING_USERS_FULL');
    });

    test('reads only the fixed authenticated Music Home browse id', () async {
      final firstPayload = <String, Object?>{'page': 'first'};
      final nextPayload = <String, Object?>{'page': 'next'};
      final transport = _FakeAccountTransport(<Object>[
        _ok(firstPayload),
        _ok(nextPayload),
      ]);
      final gateway = _gateway(transport);

      expect(await gateway.readMusicHomePage(), same(firstPayload));
      expect(
        await gateway.readMusicHomePage(continuation: ' next-home '),
        same(nextPayload),
      );

      expect(transport.requests, hasLength(2));
      expect(transport.requests.first.endpoint, 'browse');
      expect(transport.requests.first.body['context'], _clientContext);
      expect(transport.requests.first.body['browseId'], 'FEmusic_home');
      expect(transport.requests.first.body, isNot(contains('continuation')));
      expect(transport.requests.last.body['context'], _clientContext);
      expect(transport.requests.last.body['continuation'], 'next-home');
      expect(transport.requests.last.body, isNot(contains('browseId')));
    });

    test('rejects unsafe Music Home continuations before transport', () async {
      final transport = _FakeAccountTransport(<Object>[]);

      expect(
        () => _gateway(
          transport,
        ).readMusicHomePage(continuation: 'bad\ncontinuation'),
        throwsArgumentError,
      );
      expect(transport.requests, isEmpty);
    });

    test('reads saved playlists and stops on repeated continuation', () async {
      final transport = _FakeAccountTransport(<Object>[
        _ok(
          _playlistShelfFixture(
            playlistId: 'PL-one',
            title: 'Primera',
            continuation: 'same-token',
          ),
        ),
        _ok(
          _playlistShelfFixture(
            playlistId: 'PL-two',
            title: 'Segunda',
            continuation: 'same-token',
            continuationPage: true,
          ),
        ),
      ]);

      final collection = await _gateway(transport).getSavedPlaylists();

      expect(
        collection.playlists.map((playlist) => playlist.playlistId),
        <String>['PL-one', 'PL-two'],
      );
      expect(
        collection.termination,
        RemotePaginationTermination.repeatedContinuation,
      );
      expect(collection.pagesFetched, 2);
      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.first.body['browseId'],
        'FEmusic_liked_playlists',
      );
      expect(transport.requests.last.body['continuation'], 'same-token');
    });

    test(
      'reads saved playlists from the authenticated library carousel',
      () async {
        final transport = _FakeAccountTransport(<Object>[
          _ok(
            _playlistCarouselFixture(
              playlistId: 'PL-carousel',
              title: 'Desde carousel',
            ),
          ),
        ]);

        final collection = await _gateway(transport).getSavedPlaylists();

        expect(
          collection.playlists.map((playlist) => playlist.playlistId),
          <String>['PL-carousel'],
        );
        expect(collection.isComplete, isTrue);
      },
    );

    test(
      'marks a bounded playlist listing as incomplete at page limit',
      () async {
        final transport = _FakeAccountTransport(<Object>[
          _ok(
            _playlistShelfFixture(
              playlistId: 'PL-one',
              title: 'Primera',
              continuation: 'next-token',
            ),
          ),
        ]);

        final collection = await _gateway(
          transport,
          maxReadPages: 1,
        ).getSavedPlaylists();

        expect(collection.isComplete, isFalse);
        expect(collection.termination, RemotePaginationTermination.pageLimit);
        expect(transport.requests, hasLength(1));
      },
    );

    test(
      'preserves duplicate videos and their setVideoId across pages',
      () async {
        final transport = _FakeAccountTransport(<Object>[
          _ok(
            _playlistPageFixture(
              setVideoId: 'set-first',
              continuation: 'playlist-next',
              includeHeader: true,
            ),
          ),
          _ok(
            _playlistPageFixture(
              setVideoId: 'set-second',
              includeHeader: false,
              continuationPage: true,
            ),
          ),
        ]);

        final snapshot = await _gateway(
          transport,
        ).getPlaylist('VLPL-duplicate');

        expect(snapshot.playlistId, 'PL-duplicate');
        expect(snapshot.summary?.title, 'Duplicados');
        expect(snapshot.entries, hasLength(2));
        expect(snapshot.entries.map((entry) => entry.videoId), <String?>[
          'same-video',
          'same-video',
        ]);
        expect(snapshot.entries.map((entry) => entry.setVideoId), <String?>[
          'set-first',
          'set-second',
        ]);
        expect(snapshot.entries.map((entry) => entry.position), <int>[0, 1]);
        expect(snapshot.entries.first.artistBrowseIds, <String?>['UC-artist']);
        expect(
          snapshot.entries.first.duration,
          const Duration(minutes: 3, seconds: 7),
        );
        expect(snapshot.isComplete, isTrue);
      },
    );

    test(
      'ignores saved-playlist cards and continuations outside the grid',
      () async {
        final transport = _FakeAccountTransport(<Object>[
          _ok(<String, Object?>{
            'unrelatedShelf': <String, Object?>{
              'contents': <Object?>[
                _savedPlaylistItem(
                  playlistId: 'PL-decoy',
                  title: 'No importar',
                ),
                _continuationItem('decoy-token'),
              ],
            },
            ..._playlistShelfFixture(
              playlistId: 'PL-real',
              title: 'Real',
              continuation: 'real-token',
            ),
          }),
          _ok(
            _playlistShelfFixture(
              playlistId: 'PL-next',
              title: 'Siguiente',
              continuationPage: true,
            ),
          ),
        ]);

        final collection = await _gateway(transport).getSavedPlaylists();

        expect(
          collection.playlists.map((playlist) => playlist.playlistId),
          <String>['PL-real', 'PL-next'],
        );
        expect(transport.requests, hasLength(2));
        expect(transport.requests.last.body['continuation'], 'real-token');
        expect(collection.termination, RemotePaginationTermination.exhausted);
      },
    );

    test(
      'ignores entry renderers and continuations outside the playlist shelf',
      () async {
        final transport = _FakeAccountTransport(<Object>[
          _ok(<String, Object?>{
            'unrelatedShelf': <String, Object?>{
              'contents': <Object?>[
                _playlistEntryItem(
                  setVideoId: 'set-decoy-first',
                  videoId: 'decoy-video-first',
                  title: 'No reproducir',
                ),
                _continuationItem('decoy-token-first'),
              ],
            },
            ..._playlistPageFixture(
              setVideoId: 'set-real-first',
              continuation: 'real-playlist-token',
              includeHeader: true,
            ),
          }),
          _ok(<String, Object?>{
            'unrelatedShelf': <String, Object?>{
              'contents': <Object?>[
                _playlistEntryItem(
                  setVideoId: 'set-decoy-second',
                  videoId: 'decoy-video-second',
                  title: 'Tampoco reproducir',
                ),
                _continuationItem('decoy-token-second'),
              ],
            },
            ..._playlistPageFixture(
              setVideoId: 'set-real-second',
              includeHeader: false,
              continuationPage: true,
            ),
          }),
        ]);

        final snapshot = await _gateway(transport).getPlaylist('PL-scoped');

        expect(snapshot.entries, hasLength(2));
        expect(snapshot.entries.map((entry) => entry.setVideoId), <String?>[
          'set-real-first',
          'set-real-second',
        ]);
        expect(
          snapshot.entries.map((entry) => entry.videoId),
          everyElement('same-video'),
        );
        expect(transport.requests, hasLength(2));
        expect(
          transport.requests.last.body['continuation'],
          'real-playlist-token',
        );
        expect(snapshot.termination, RemotePaginationTermination.exhausted);
      },
    );

    test('uses legacy renderer fallback only for one collection', () {
      const parser = YouTubeMusicAccountParser();
      final uniqueLegacy = <String, Object?>{
        'contents': <Object?>[
          _savedPlaylistItem(playlistId: 'PL-legacy', title: 'Compatibilidad'),
          _continuationItem('legacy-token'),
        ],
      };
      final ambiguousLegacy = <String, Object?>{
        'first': <String, Object?>{
          'contents': <Object?>[
            _playlistEntryItem(setVideoId: 'legacy-first'),
            _continuationItem('legacy-first-token'),
          ],
        },
        'second': <String, Object?>{
          'contents': <Object?>[
            _playlistEntryItem(setVideoId: 'legacy-second'),
            _continuationItem('legacy-second-token'),
          ],
        },
      };

      expect(
        parser
            .parsePlaylistSummaries(uniqueLegacy)
            .map((playlist) => playlist.playlistId),
        <String>['PL-legacy'],
      );
      expect(
        parser.parseSavedPlaylistContinuationTokens(uniqueLegacy),
        <String>['legacy-token'],
      );
      expect(
        parser.parsePlaylistEntries(ambiguousLegacy, startingPosition: 0),
        isEmpty,
      );
      expect(
        parser.parsePlaylistEntryContinuationTokens(ambiguousLegacy),
        isEmpty,
      );
    });

    test('retries reads only within the configured bound', () async {
      final delays = <Duration>[];
      final transport = _FakeAccountTransport(<Object>[
        YouTubeMusicAccountResponse(
          statusCode: 503,
          body: const <String, Object?>{},
        ),
        const YouTubeMusicAccountTransportException(
          delivery: YouTubeMusicRequestDelivery.notSent,
          retryableForRead: true,
        ),
        _ok(_profileFixture()),
      ]);
      final gateway = _gateway(
        transport,
        retryDelay: (duration) async => delays.add(duration),
      );

      final profile = await gateway.getProfile();

      expect(profile?.displayName, 'BStream User');
      expect(transport.requests, hasLength(3));
      expect(delays, const <Duration>[
        Duration(milliseconds: 1),
        Duration(milliseconds: 2),
      ]);
    });
  });

  group('playlist mutations', () {
    test('uses the exact create endpoint and parses its playlist id', () async {
      final transport = _FakeAccountTransport(<Object>[
        _ok(const <String, Object?>{'playlistId': 'VLPL-created'}),
      ]);

      final result = await _gateway(transport).createPlaylist(
        'Viaje',
        visibility: RemotePlaylistVisibility.unlisted,
        initialVideoIds: const <String>['video-a', 'video-b'],
      );

      expect(result, isA<YouTubeMusicMutationSuccess<RemotePlaylistCreated>>());
      final value =
          (result as YouTubeMusicMutationSuccess<RemotePlaylistCreated>).value;
      expect(value.playlistId, 'PL-created');
      final request = transport.requests.single;
      expect(request.endpoint, 'playlist/create');
      expect(request.kind, YouTubeMusicAccountRequestKind.mutation);
      expect(request.body['title'], 'Viaje');
      expect(request.body['privacyStatus'], 'UNLISTED');
      expect(request.body['videoIds'], <String>['video-a', 'video-b']);
    });

    test('liked music mutations use like and removelike endpoints', () async {
      final transport = _FakeAccountTransport(<Object>[
        _ok(const <String, Object?>{}),
        _ok(const <String, Object?>{}),
      ]);
      final gateway = _gateway(transport);

      final liked = await gateway.likeVideo('video-like');
      final unliked = await gateway.removeLike('video-unlike');

      expect(
        liked,
        isA<YouTubeMusicMutationSuccess<RemotePlaylistMutationApplied>>(),
      );
      expect(
        unliked,
        isA<YouTubeMusicMutationSuccess<RemotePlaylistMutationApplied>>(),
      );
      expect(transport.requests.map((request) => request.endpoint), <String>[
        'like/like',
        'like/removelike',
      ]);
      expect(
        (transport.requests.first.body['target'] as Map)['videoId'],
        'video-like',
      );
      expect(
        (transport.requests.last.body['target'] as Map)['videoId'],
        'video-unlike',
      );
    });

    test(
      'artist subscription read uses a UC browse id when renderer omits channel',
      () async {
        final transport = _FakeAccountTransport(<Object>[
          _ok(<String, Object?>{
            'header': <String, Object?>{
              'musicImmersiveHeaderRenderer': <String, Object?>{
                'subscriptionButton': <String, Object?>{
                  'musicSubscribeButtonRenderer': <String, Object?>{
                    'subscribed': true,
                  },
                },
              },
            },
          }),
        ]);
        final gateway = _gateway(transport);

        final state = await gateway.getArtistSubscriptionState('UCartist123');

        expect(state?.channelId, 'UCartist123');
        expect(state?.isSubscribed, isTrue);
        expect(transport.requests.single.endpoint, 'browse');
        expect(transport.requests.single.body['browseId'], 'UCartist123');
      },
    );

    test('MPLA browse id is not reused as a subscription channel id', () async {
      final transport = _FakeAccountTransport(<Object>[
        _ok(<String, Object?>{
          'musicSubscribeButtonRenderer': <String, Object?>{
            'subscribed': false,
          },
        }),
      ]);
      final gateway = _gateway(transport);

      final state = await gateway.getArtistSubscriptionState('MPLAartist123');

      expect(state, isNull);
    });

    test('artist subscription mutations use channelIds exactly once', () async {
      final transport = _FakeAccountTransport(<Object>[
        _ok(const <String, Object?>{}),
        _ok(const <String, Object?>{}),
      ]);
      final gateway = _gateway(transport);

      final subscribed = await gateway.subscribeArtist('UCartist123');
      final unsubscribed = await gateway.unsubscribeArtist('UCartist123');

      expect(
        subscribed,
        isA<YouTubeMusicMutationSuccess<RemotePlaylistMutationApplied>>(),
      );
      expect(
        unsubscribed,
        isA<YouTubeMusicMutationSuccess<RemotePlaylistMutationApplied>>(),
      );
      expect(transport.requests.map((request) => request.endpoint), <String>[
        'subscription/subscribe',
        'subscription/unsubscribe',
      ]);
      expect(
        transport.requests.map((request) => request.body['channelIds']),
        everyElement(<String>['UCartist123']),
      );
      expect(transport.requests, hasLength(2));
    });

    test('encodes add, remove, move, metadata and delete operations', () async {
      final transport = _FakeAccountTransport(
        List<Object>.filled(6, _ok(const <String, Object?>{})),
      );
      final gateway = _gateway(transport);
      final occurrence = RemotePlaylistEntry(
        position: 4,
        videoId: 'video-a',
        setVideoId: 'set-a',
        title: 'Track',
        artists: const <String>['Artist'],
      );

      await gateway.addPlaylistEntry(
        playlistId: 'VLPL-list',
        videoId: 'video-a',
      );
      await gateway.removePlaylistEntry(
        playlistId: 'PL-list',
        entry: occurrence,
      );
      await gateway.movePlaylistEntry(
        playlistId: 'PL-list',
        setVideoId: 'set-a',
        successorSetVideoId: 'set-b',
      );
      await gateway.renamePlaylist(playlistId: 'PL-list', title: 'Nuevo');
      await gateway.setPlaylistDescription(
        playlistId: 'PL-list',
        description: 'Descripción',
      );
      await gateway.deletePlaylist('VLPL-list');

      expect(
        transport.requests.map((request) => request.endpoint),
        const <String>[
          'browse/edit_playlist',
          'browse/edit_playlist',
          'browse/edit_playlist',
          'browse/edit_playlist',
          'browse/edit_playlist',
          'playlist/delete',
        ],
      );
      expect(_action(transport.requests[0]), <String, Object?>{
        'action': 'ACTION_ADD_VIDEO',
        'addedVideoId': 'video-a',
      });
      expect(_action(transport.requests[1]), <String, Object?>{
        'action': 'ACTION_REMOVE_VIDEO',
        'setVideoId': 'set-a',
        'removedVideoId': 'video-a',
      });
      expect(_action(transport.requests[2]), <String, Object?>{
        'action': 'ACTION_MOVE_VIDEO_BEFORE',
        'setVideoId': 'set-a',
        'movedSetVideoIdSuccessor': 'set-b',
      });
      expect(_action(transport.requests[3])['playlistName'], 'Nuevo');
      expect(
        _action(transport.requests[4])['playlistDescription'],
        'Descripción',
      );
      expect(transport.requests.last.body['playlistId'], 'PL-list');
      expect(
        transport.requests
            .take(5)
            .every((request) => request.body['playlistId'] == 'PL-list'),
        isTrue,
      );
    });

    test('never retries a mutation with uncertain delivery', () async {
      final transport = _FakeAccountTransport(<Object>[
        const YouTubeMusicAccountTransportException(
          delivery: YouTubeMusicRequestDelivery.possiblySent,
          retryableForRead: true,
        ),
        _ok(const <String, Object?>{}),
      ]);

      final result = await _gateway(
        transport,
      ).addPlaylistEntry(playlistId: 'PL-list', videoId: 'video-a');

      expect(
        result,
        isA<YouTubeMusicMutationAmbiguous<RemotePlaylistMutationApplied>>(),
      );
      expect(transport.requests, hasLength(1));
    });

    test(
      'classifies a transient mutation HTTP response as ambiguous',
      () async {
        final transport = _FakeAccountTransport(<Object>[
          YouTubeMusicAccountResponse(
            statusCode: 503,
            body: const <String, Object?>{},
          ),
        ]);

        final result = await _gateway(transport).deletePlaylist('PL-list');

        expect(
          result,
          isA<YouTubeMusicMutationAmbiguous<RemotePlaylistMutationApplied>>(),
        );
        expect(transport.requests, hasLength(1));
      },
    );
  });

  test('session and request diagnostics redact authentication headers', () {
    final headers = YouTubeMusicSessionHeaders(const <String, String>{
      'Authorization': 'SAPISIDHASH top-secret-signature',
      'Cookie': 'SAPISID=top-secret-cookie',
      'X-Goog-Visitor-Id': 'top-secret-visitor',
      'X-Goog-AuthUser': '7',
      'Content-Type': 'application/json',
    });
    final request = YouTubeMusicAccountRequest(
      endpoint: 'browse',
      kind: YouTubeMusicAccountRequestKind.read,
      headers: headers.toTransportMap(),
      body: const <String, Object?>{'browseId': 'FEmusic_liked_playlists'},
      timeout: const Duration(seconds: 1),
    );

    final diagnostics = '${headers.toString()} ${request.toString()}';
    expect(diagnostics, isNot(contains('top-secret')));
    expect(diagnostics, isNot(contains('AuthUser: 7')));
    expect(diagnostics, contains('<redacted>'));
    expect(diagnostics, contains('application/json'));
  });
}

const Map<String, Object?> _clientContext = <String, Object?>{
  'client': <String, Object?>{
    'clientName': 'WEB_REMIX',
    'clientVersion': 'test-version',
    'hl': 'es-419',
    'gl': 'NI',
  },
};

YouTubeMusicAccountGateway _gateway(
  _FakeAccountTransport transport, {
  int maxReadPages = 10,
  YouTubeMusicAccountRetryDelay? retryDelay,
}) {
  return YouTubeMusicAccountGateway(
    transport: transport,
    sessionHeaders: StaticYouTubeMusicSessionHeadersProvider(
      YouTubeMusicSessionHeaders(const <String, String>{
        'Authorization': 'SAPISIDHASH fixture',
        'Cookie': 'SAPISID=fixture',
      }),
    ),
    clientContext: _clientContext,
    maxReadPages: maxReadPages,
    readRetryPolicy: const YouTubeMusicAccountReadRetryPolicy(
      maxAttempts: 3,
      backoff: <Duration>[Duration(milliseconds: 1), Duration(milliseconds: 2)],
    ),
    retryDelay: retryDelay ?? (_) async {},
  );
}

YouTubeMusicAccountResponse _ok(Object? body) =>
    YouTubeMusicAccountResponse(statusCode: 200, body: body);

Map<String, Object?> _profileFixture() => <String, Object?>{
  'actions': <Object?>[
    <String, Object?>{
      'openPopupAction': <String, Object?>{
        'popup': <String, Object?>{
          'multiPageMenuRenderer': <String, Object?>{
            'header': <String, Object?>{
              'activeAccountHeaderRenderer': <String, Object?>{
                'accountName': _runs('BStream User'),
                'email': _runs('listener@example.test'),
                'channelHandle': _runs('@bstream'),
                'accountPhoto': <String, Object?>{
                  'thumbnails': <Object?>[
                    <String, Object?>{
                      'url': 'https://img.test/avatar-small.jpg',
                      'width': 32,
                      'height': 32,
                    },
                    <String, Object?>{
                      'url': 'https://img.test/avatar-large.jpg',
                      'width': 128,
                      'height': 128,
                    },
                  ],
                },
                'navigationEndpoint': <String, Object?>{
                  'browseEndpoint': <String, Object?>{'browseId': 'UC-profile'},
                },
              },
            },
          },
        },
      },
    },
  ],
};

Map<String, Object?> _accountsFixture() => <String, Object?>{
  'actions': <Object?>[
    <String, Object?>{
      'getMultiPageMenuAction': <String, Object?>{
        'menu': <String, Object?>{
          'multiPageMenuRenderer': <String, Object?>{
            'sections': <Object?>[
              <String, Object?>{
                'accountSectionListRenderer': <String, Object?>{
                  'header': <String, Object?>{
                    'googleAccountHeaderRenderer': <String, Object?>{
                      'name': _runs('Google User'),
                      'email': _runs('listener@example.test'),
                    },
                  },
                  'contents': <Object?>[
                    <String, Object?>{
                      'accountItemSectionRenderer': <String, Object?>{
                        'contents': <Object?>[
                          <String, Object?>{
                            'accountItem': _accountItem(
                              name: 'Main channel',
                              handle: '@main',
                              pageId: 'UC-main',
                              dataSyncId: 'UC-main||sync',
                              selected: true,
                            ),
                          },
                          <String, Object?>{
                            'accountItem': _accountItem(
                              name: 'Brand channel',
                              handle: '@brand',
                              pageId: 'UC-brand',
                              dataSyncId: 'UC-brand||sync',
                            ),
                          },
                        ],
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      },
    },
  ],
};

Map<String, Object?> _accountItem({
  required String name,
  required String handle,
  required String pageId,
  required String dataSyncId,
  bool selected = false,
}) => <String, Object?>{
  'accountName': _runs(name),
  'channelHandle': _runs(handle),
  'accountPhoto': <String, Object?>{
    'thumbnails': <Object?>[
      <String, Object?>{
        'url': 'https://img.test/$pageId.jpg',
        'width': 64,
        'height': 64,
      },
    ],
  },
  'isSelected': selected,
  'serviceEndpoint': <String, Object?>{
    'selectActiveIdentityEndpoint': <String, Object?>{
      'supportedTokens': <Object?>[
        <String, Object?>{
          'pageIdToken': <String, Object?>{'pageId': pageId},
        },
        <String, Object?>{
          'datasyncIdToken': <String, Object?>{'datasyncIdToken': dataSyncId},
        },
        <String, Object?>{
          'accountSigninToken': <String, Object?>{
            'signinUrl': 'https://music.youtube.com/channel-switch/main',
          },
        },
      ],
    },
  },
};

Map<String, Object?> _playlistShelfFixture({
  required String playlistId,
  required String title,
  String? continuation,
  bool continuationPage = false,
}) {
  final items = <Object?>[
    _savedPlaylistItem(playlistId: playlistId, title: title),
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
        'sectionListRenderer': <String, Object?>{
          'contents': <Object?>[
            <String, Object?>{
              'gridRenderer': <String, Object?>{'items': items},
            },
          ],
        },
      },
    ],
  };
}

Map<String, Object?> _playlistCarouselFixture({
  required String playlistId,
  required String title,
}) => <String, Object?>{
  'contents': <Object?>[
    <String, Object?>{
      'sectionListRenderer': <String, Object?>{
        'contents': <Object?>[
          <String, Object?>{
            'musicCarouselShelfRenderer': <String, Object?>{
              'contents': <Object?>[
                _savedPlaylistItem(playlistId: playlistId, title: title),
              ],
            },
          },
        ],
      },
    },
  ],
};

Map<String, Object?> _savedPlaylistItem({
  required String playlistId,
  required String title,
}) => <String, Object?>{
  'musicTwoRowItemRenderer': <String, Object?>{
    'title': _runs(title),
    'subtitle': <String, Object?>{
      'runs': <Object?>[
        <String, Object?>{'text': 'BStream User'},
        <String, Object?>{'text': ' • '},
        <String, Object?>{'text': '3 canciones'},
      ],
    },
    'navigationEndpoint': <String, Object?>{
      'browseEndpoint': <String, Object?>{'browseId': 'VL$playlistId'},
    },
    'thumbnailRenderer': <String, Object?>{
      'musicThumbnailRenderer': <String, Object?>{
        'thumbnail': <String, Object?>{
          'thumbnails': <Object?>[
            <String, Object?>{
              'url': 'https://img.test/$playlistId.jpg',
              'width': 256,
              'height': 256,
            },
          ],
        },
      },
    },
  },
};

Map<String, Object?> _playlistPageFixture({
  required String setVideoId,
  String? continuation,
  required bool includeHeader,
  bool continuationPage = false,
}) {
  final shelf = <String, Object?>{
    'contents': <Object?>[
      _playlistEntryItem(setVideoId: setVideoId),
      if (continuation != null) _continuationItem(continuation),
    ],
  };
  if (continuationPage) {
    return <String, Object?>{
      'continuationContents': <String, Object?>{
        'musicPlaylistShelfContinuation': shelf,
      },
    };
  }
  return <String, Object?>{
    if (includeHeader)
      'header': <String, Object?>{
        'musicEditablePlaylistDetailHeaderRenderer': <String, Object?>{
          'title': _runs('Duplicados'),
          'subtitle': _runs('2 canciones'),
          'editPlaylistEndpoint': <String, Object?>{},
        },
      },
    'contents': <Object?>[
      <String, Object?>{
        'sectionListRenderer': <String, Object?>{
          'contents': <Object?>[
            <String, Object?>{'musicPlaylistShelfRenderer': shelf},
          ],
        },
      },
    ],
  };
}

Map<String, Object?> _playlistEntryItem({
  required String setVideoId,
  String videoId = 'same-video',
  String title = 'Repeated song',
}) => <String, Object?>{
  'musicResponsiveListItemRenderer': <String, Object?>{
    'playlistItemData': <String, Object?>{
      'videoId': videoId,
      'playlistSetVideoId': setVideoId,
    },
    'flexColumns': <Object?>[
      <String, Object?>{
        'musicResponsiveListItemFlexColumnRenderer': <String, Object?>{
          'text': _runs(title),
        },
      },
      <String, Object?>{
        'musicResponsiveListItemFlexColumnRenderer': <String, Object?>{
          'text': <String, Object?>{
            'runs': <Object?>[
              <String, Object?>{
                'text': 'Artist',
                'navigationEndpoint': <String, Object?>{
                  'browseEndpoint': <String, Object?>{
                    'browseId': 'UC-artist',
                    'browseEndpointContextSupportedConfigs': <String, Object?>{
                      'browseEndpointContextMusicConfig': <String, Object?>{
                        'pageType': 'MUSIC_PAGE_TYPE_ARTIST',
                      },
                    },
                  },
                },
              },
              <String, Object?>{'text': ' • '},
              <String, Object?>{
                'text': 'Album',
                'navigationEndpoint': <String, Object?>{
                  'browseEndpoint': <String, Object?>{
                    'browseId': 'MPRE-album',
                    'browseEndpointContextSupportedConfigs': <String, Object?>{
                      'browseEndpointContextMusicConfig': <String, Object?>{
                        'pageType': 'MUSIC_PAGE_TYPE_ALBUM',
                      },
                    },
                  },
                },
              },
            ],
          },
        },
      },
    ],
    'fixedColumns': <Object?>[
      <String, Object?>{
        'musicResponsiveListItemFixedColumnRenderer': <String, Object?>{
          'text': _runs('3:07'),
        },
      },
    ],
    'thumbnail': <String, Object?>{
      'musicThumbnailRenderer': <String, Object?>{
        'thumbnail': <String, Object?>{
          'thumbnails': <Object?>[
            <String, Object?>{
              'url': 'https://img.test/song.jpg',
              'width': 120,
              'height': 120,
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

Map<String, Object?> _runs(String text) => <String, Object?>{
  'runs': <Object?>[
    <String, Object?>{'text': text},
  ],
};

Map<String, Object?> _action(YouTubeMusicAccountRequest request) {
  final actions = request.body['actions']! as List<Object?>;
  return actions.single! as Map<String, Object?>;
}

class _FakeAccountTransport implements YouTubeMusicAccountTransport {
  _FakeAccountTransport(List<Object> outcomes)
    : _outcomes = List<Object>.of(outcomes);

  final List<Object> _outcomes;
  final List<YouTubeMusicAccountRequest> requests =
      <YouTubeMusicAccountRequest>[];

  @override
  Future<YouTubeMusicAccountResponse> send(
    YouTubeMusicAccountRequest request,
  ) async {
    requests.add(request);
    if (_outcomes.isEmpty) {
      throw StateError('No fixture response remains.');
    }
    final outcome = _outcomes.removeAt(0);
    if (outcome is YouTubeMusicAccountResponse) {
      return outcome;
    }
    throw outcome;
  }
}
