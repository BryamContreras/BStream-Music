import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'artist parser separates popular songs, albums, singles and actions',
    () {
      const parser = InnerTubeArtistParser();

      final profile = parser.parse(<String, Object?>{
        'header': <String, Object?>{
          'musicImmersiveHeaderRenderer': <String, Object?>{
            'title': _text('Artista Uno'),
            'subscriberCountText': _text('1.2 M suscriptores'),
            'monthlyListenerCount': _text('Público mensual: 8.7 M usuarios'),
            'thumbnail': _thumbnails('https://img.test/artist.jpg'),
            'subscriptionButton': <String, Object?>{
              'subscribeButtonRenderer': <String, Object?>{
                'channelId': 'UCartist123',
                'subscribed': true,
              },
            },
            'playButton': <String, Object?>{
              'buttonRenderer': <String, Object?>{
                'navigationEndpoint': <String, Object?>{
                  'watchEndpoint': <String, Object?>{
                    'playlistId': 'RDAOartistPlay123',
                  },
                },
              },
            },
            'startRadioButton': <String, Object?>{
              'buttonRenderer': <String, Object?>{
                'navigationEndpoint': <String, Object?>{
                  'watchEndpoint': <String, Object?>{
                    'videoId': 'radioSeed01',
                    'playlistId': 'RDEMartistRadio123',
                  },
                },
              },
            },
          },
        },
        'contents': <Object?>[
          <String, Object?>{
            'musicDescriptionShelfRenderer': <String, Object?>{
              'description': _text('Descripción oficial del artista.'),
            },
          },
          <String, Object?>{
            'musicShelfRenderer': <String, Object?>{
              'title': _text('Canciones más populares'),
              'contents': <Object?>[
                _song(
                  videoId: 'popular0001',
                  title: 'Canción Uno',
                  artist: 'Artista Uno',
                  album: 'Álbum Uno',
                  albumBrowseId: 'MPREalbum123',
                ),
              ],
            },
          },
          _releaseShelf(
            title: 'Álbumes',
            release: _release(
              browseId: 'MPREalbum123',
              title: 'Álbum Uno',
              type: 'Álbum',
            ),
          ),
          _releaseShelf(
            title: 'Sencillos',
            release: _release(browseId: 'MPREsingle123', title: 'Sencillo Uno'),
          ),
        ],
      }, artistBrowseId: 'UCartist123');

      expect(profile.artist.name, 'Artista Uno');
      expect(profile.artist.thumbnailUrl, 'https://img.test/artist.jpg');
      expect(profile.subscriberCount, '1.2 M suscriptores');
      expect(profile.monthlyListenerCount, 'Público mensual: 8.7 M usuarios');
      expect(profile.description, 'Descripción oficial del artista.');
      expect(profile.channelId, 'UCartist123');
      expect(profile.isSubscribed, isTrue);
      expect(profile.playPlaylistId, 'RDAOartistPlay123');
      expect(profile.radioPlaylistId, 'RDEMartistRadio123');
      expect(profile.radioSeedVideoId, 'radioSeed01');
      expect(profile.popularSongs.single.videoId, 'popular0001');
      expect(profile.popularSongs.single.albumBrowseId, 'MPREalbum123');
      expect(profile.albums.single.title, 'Álbum Uno');
      expect(profile.singles.single.title, 'Sencillo Uno');
      expect(profile.relatedArtists, isEmpty);
    },
  );

  test('artist metrics prefer a labeled subscriber count when available', () {
    const parser = InnerTubeArtistParser();

    final profile = parser.parse(<String, Object?>{
      'header': <String, Object?>{
        'musicImmersiveHeaderRenderer': <String, Object?>{
          'title': _text('Artista Uno'),
          'subscriptionButton': <String, Object?>{
            'subscribeButtonRenderer': <String, Object?>{
              'subscriberCountText': _text('41.5 M'),
              'longSubscriberCountText': _text('41.5 M de suscriptores'),
            },
          },
          'monthlyListenerCount': _text('Público mensual: 165 M usuarios'),
        },
      },
    }, artistBrowseId: 'UCartist123');

    expect(profile.subscriberCount, '41.5 M de suscriptores');
    expect(profile.monthlyListenerCount, 'Público mensual: 165 M usuarios');
  });

  test('artist metrics remain absent when YouTube does not publish them', () {
    const parser = InnerTubeArtistParser();

    final profile = parser.parse(<String, Object?>{
      'header': <String, Object?>{
        'musicImmersiveHeaderRenderer': <String, Object?>{
          'title': _text('Artista sin métricas'),
        },
      },
    }, artistBrowseId: 'UCartist123');

    expect(profile.subscriberCount, isNull);
    expect(profile.monthlyListenerCount, isNull);
  });

  test('UC artist browse id is retained when subscribe renderer omits it', () {
    const parser = InnerTubeArtistParser();

    final profile = parser.parse(<String, Object?>{
      'header': <String, Object?>{
        'musicImmersiveHeaderRenderer': <String, Object?>{
          'title': _text('Artista Uno'),
          'subscriptionButton': <String, Object?>{
            'musicSubscribeButtonRenderer': <String, Object?>{
              'subscribed': false,
            },
          },
        },
      },
    }, artistBrowseId: 'UCartist123');

    expect(profile.channelId, 'UCartist123');
    expect(profile.isSubscribed, isFalse);
  });

  test('MPLA artist browse id is never exposed as a mutation channel id', () {
    const parser = InnerTubeArtistParser();

    final profile = parser.parse(<String, Object?>{
      'header': <String, Object?>{
        'musicImmersiveHeaderRenderer': <String, Object?>{
          'title': _text('Artista Uno'),
        },
      },
    }, artistBrowseId: 'MPLAartist123');

    expect(profile.channelId, isNull);
  });

  test(
    'artist Play uses only the header action and supports shuffle fallback',
    () {
      const parser = InnerTubeArtistParser();

      final profile = parser.parse(<String, Object?>{
        'header': <String, Object?>{
          'musicResponsiveHeaderRenderer': <String, Object?>{
            'title': _text('Artista Uno'),
            'shufflePlayButton': <String, Object?>{
              'musicPlayButtonRenderer': <String, Object?>{
                'playNavigationEndpoint': <String, Object?>{
                  'watchPlaylistEndpoint': <String, Object?>{
                    'playlistId': 'RDAOshuffleArtist123',
                  },
                },
              },
            },
          },
        },
        'contents': <Object?>[
          <String, Object?>{
            'playButton': <String, Object?>{
              'buttonRenderer': <String, Object?>{
                'navigationEndpoint': <String, Object?>{
                  'watchEndpoint': <String, Object?>{
                    'playlistId': 'RDAOwrongShelf123',
                  },
                },
              },
            },
          },
        ],
      }, artistBrowseId: 'UCartist123');

      expect(profile.playPlaylistId, 'RDAOshuffleArtist123');
    },
  );

  test('artist Play ignores actions outside the artist header', () {
    const parser = InnerTubeArtistParser();

    final profile = parser.parse(<String, Object?>{
      'header': <String, Object?>{
        'musicImmersiveHeaderRenderer': <String, Object?>{
          'title': _text('Artista Uno'),
        },
      },
      'contents': <Object?>[
        <String, Object?>{
          'musicShelfRenderer': <String, Object?>{
            'playButton': <String, Object?>{
              'buttonRenderer': <String, Object?>{
                'navigationEndpoint': <String, Object?>{
                  'watchEndpoint': <String, Object?>{
                    'playlistId': 'RDAOwrongShelf123',
                  },
                },
              },
            },
          },
        },
      ],
    }, artistBrowseId: 'UCartist123');

    expect(profile.playPlaylistId, isNull);
  });

  test(
    'extracts artist carousel cards without relying on its localized title',
    () {
      const parser = InnerTubeArtistParser();
      final relatedCards = <Map<String, Object?>>[
        _artistCard(browseId: 'UCartist123', name: 'El mismo artista'),
        ...List<Map<String, Object?>>.generate(
          13,
          (index) => _artistCard(
            browseId: 'UCrelated${index.toString().padLeft(2, '0')}',
            name: 'Relacionado $index',
            endpointOnTitleOnly: index.isOdd,
          ),
        ),
        _artistCard(browseId: 'UCrelated00', name: 'Duplicado con otro nombre'),
        _release(browseId: 'MPREnotanartist', title: 'No es un artista'),
      ];

      final profile = parser.parse(<String, Object?>{
        'contents': <Object?>[
          <String, Object?>{
            'musicCarouselShelfRenderer': <String, Object?>{
              'header': <String, Object?>{
                'musicCarouselShelfBasicHeaderRenderer': <String, Object?>{
                  'title': _text('Un tÃ­tulo nuevo que el parser no conoce'),
                },
              },
              'contents': relatedCards,
            },
          },
        ],
      }, artistBrowseId: 'UCartist123');

      expect(profile.relatedArtists, hasLength(12));
      expect(
        profile.relatedArtists.map((artist) => artist.browseId),
        List<String>.generate(
          12,
          (index) => 'UCrelated${index.toString().padLeft(2, '0')}',
        ),
      );
      expect(
        profile.relatedArtists.map((artist) => artist.name),
        isNot(contains('El mismo artista')),
      );
      expect(
        profile.relatedArtists.first.thumbnailUrl,
        'https://img.test/UCrelated00.jpg',
      );
    },
  );
}

Map<String, Object?> _text(String value) => <String, Object?>{
  'runs': <Object?>[
    <String, Object?>{'text': value},
  ],
};

Map<String, Object?> _thumbnails(String url) => <String, Object?>{
  'musicThumbnailRenderer': <String, Object?>{
    'thumbnail': <String, Object?>{
      'thumbnails': <Object?>[
        <String, Object?>{'url': url, 'width': 512, 'height': 512},
      ],
    },
  },
};

Map<String, Object?> _song({
  required String videoId,
  required String title,
  required String artist,
  String? album,
  String? albumBrowseId,
}) => <String, Object?>{
  'musicResponsiveListItemRenderer': <String, Object?>{
    'playlistItemData': <String, Object?>{'videoId': videoId},
    'flexColumns': <Object?>[
      <String, Object?>{
        'musicResponsiveListItemFlexColumnRenderer': <String, Object?>{
          'text': _text(title),
        },
      },
      <String, Object?>{
        'musicResponsiveListItemFlexColumnRenderer': <String, Object?>{
          'text': <String, Object?>{
            'runs': <Object?>[
              <String, Object?>{
                'text': artist,
                'navigationEndpoint': _artistEndpoint(),
              },
              if (album != null) ...<Object?>[
                const <String, Object?>{'text': ' • '},
                <String, Object?>{
                  'text': album,
                  'navigationEndpoint': _albumEndpoint(
                    albumBrowseId ?? 'MPREalbumFallback',
                  ),
                },
              ],
              const <String, Object?>{'text': ' • '},
              const <String, Object?>{'text': '3:14'},
            ],
          },
        },
      },
    ],
  },
};

Map<String, Object?> _releaseShelf({
  required String title,
  required Map<String, Object?> release,
}) => <String, Object?>{
  'musicCarouselShelfRenderer': <String, Object?>{
    'header': <String, Object?>{
      'musicCarouselShelfBasicHeaderRenderer': <String, Object?>{
        'title': _text(title),
      },
    },
    'contents': <Object?>[release],
  },
};

Map<String, Object?> _release({
  required String browseId,
  required String title,
  String? type,
}) => <String, Object?>{
  'musicTwoRowItemRenderer': <String, Object?>{
    'title': <String, Object?>{
      'runs': <Object?>[
        <String, Object?>{
          'text': title,
          'navigationEndpoint': _albumEndpoint(browseId),
        },
      ],
    },
    'navigationEndpoint': _albumEndpoint(browseId),
    'subtitle': <String, Object?>{
      'runs': <Object?>[
        if (type != null) ...<Object?>[
          <String, Object?>{'text': type},
          const <String, Object?>{'text': ' • '},
        ],
        <String, Object?>{
          'text': 'Artista Uno',
          'navigationEndpoint': _artistEndpoint(),
        },
        const <String, Object?>{'text': ' • '},
        const <String, Object?>{'text': '2026'},
      ],
    },
    'thumbnailRenderer': _thumbnails('https://img.test/$browseId.jpg'),
  },
};

Map<String, Object?> _artistCard({
  required String browseId,
  required String name,
  bool endpointOnTitleOnly = false,
}) {
  final endpoint = _artistEndpointFor(browseId);
  return <String, Object?>{
    'musicTwoRowItemRenderer': <String, Object?>{
      'title': <String, Object?>{
        'runs': <Object?>[
          <String, Object?>{
            'text': name,
            if (endpointOnTitleOnly) 'navigationEndpoint': endpoint,
          },
        ],
      },
      if (!endpointOnTitleOnly) 'navigationEndpoint': endpoint,
      'thumbnailRenderer': _thumbnails('https://img.test/$browseId.jpg'),
    },
  };
}

Map<String, Object?> _artistEndpoint() => <String, Object?>{
  'browseEndpoint': <String, Object?>{
    'browseId': 'UCartist123',
    'browseEndpointContextSupportedConfigs': <String, Object?>{
      'browseEndpointContextMusicConfig': <String, Object?>{
        'pageType': 'MUSIC_PAGE_TYPE_ARTIST',
      },
    },
  },
};

Map<String, Object?> _artistEndpointFor(String browseId) => <String, Object?>{
  'browseEndpoint': <String, Object?>{
    'browseId': browseId,
    'browseEndpointContextSupportedConfigs': <String, Object?>{
      'browseEndpointContextMusicConfig': <String, Object?>{
        'pageType': 'MUSIC_PAGE_TYPE_ARTIST',
      },
    },
  },
};

Map<String, Object?> _albumEndpoint(String browseId) => <String, Object?>{
  'browseEndpoint': <String, Object?>{
    'browseId': browseId,
    'browseEndpointContextSupportedConfigs': <String, Object?>{
      'browseEndpointContextMusicConfig': <String, Object?>{
        'pageType': 'MUSIC_PAGE_TYPE_ALBUM',
      },
    },
  },
};
