import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('authenticated Home adapter parses one bounded continuation', () async {
    final account = _FakeAccountHome(<Object?>[
      _homePage(
        title: 'Primera sección',
        browseId: 'VLPL-auth-home-first',
        continuation: 'home-next',
      ),
      _homePage(title: 'Segunda sección', browseId: 'VLPL-auth-home-second'),
    ]);
    final home = AuthenticatedYouTubeMusicHome(account: account);

    final sections = await home.getHome(maxSections: 2, maxItemsPerSection: 8);

    expect(sections.map((section) => section.title), <String>[
      'Primera sección',
      'Segunda sección',
    ]);
    expect(
      sections
          .expand((section) => section.collections)
          .map((item) => item.browseId),
      <String>['VLPL-auth-home-first', 'VLPL-auth-home-second'],
    );
    expect(account.continuations, <String?>[null, 'home-next']);
  });

  test('authenticated Home adapter rejects malformed successful payload', () {
    final home = AuthenticatedYouTubeMusicHome(
      account: _FakeAccountHome(<Object?>['not-a-json-object']),
    );

    expect(
      () => home.getHome(maxSections: 1),
      throwsA(isA<InnerTubeFormatException>()),
    );
  });
}

class _FakeAccountHome implements YouTubeMusicAccountHome {
  _FakeAccountHome(List<Object?> payloads)
    : _payloads = List<Object?>.of(payloads);

  final List<Object?> _payloads;
  final List<String?> continuations = <String?>[];

  @override
  Future<Object?> readMusicHomePage({String? continuation}) async {
    continuations.add(continuation);
    return _payloads.removeAt(0);
  }
}

Map<String, Object?> _homePage({
  required String title,
  required String browseId,
  String? continuation,
}) {
  return <String, Object?>{
    'musicCarouselShelfRenderer': <String, Object?>{
      'header': <String, Object?>{
        'musicCarouselShelfBasicHeaderRenderer': <String, Object?>{
          'title': _runs(title),
        },
      },
      'contents': <Object?>[
        <String, Object?>{
          'musicTwoRowItemRenderer': <String, Object?>{
            'title': _runs('Colección $title'),
            'navigationEndpoint': <String, Object?>{
              'browseEndpoint': <String, Object?>{'browseId': browseId},
            },
          },
        },
      ],
    },
    if (continuation != null)
      'continuations': <Object?>[
        <String, Object?>{
          'nextContinuationData': <String, Object?>{
            'continuation': continuation,
          },
        },
      ],
  };
}

Map<String, Object?> _runs(String text) => <String, Object?>{
  'runs': <Object?>[
    <String, Object?>{'text': text},
  ],
};
