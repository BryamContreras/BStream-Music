import 'package:flutter_test/flutter_test.dart';

import 'package:bstream_music/services/sharing/youtube_music_link.dart';

void main() {
  const codec = YouTubeMusicLinkCodec();

  test('parses YouTube Music and YouTube watch links as tracks', () {
    final music = codec.tryDecode(
      Uri.parse('https://music.youtube.com/watch?v=dQw4w9WgXcQ'),
    );
    final short = codec.tryDecode(
      Uri.parse('https://youtu.be/dQw4w9WgXcQ?t=20'),
    );

    expect(music?.kind, YouTubeMusicLinkKind.track);
    expect(music?.videoId, 'dQw4w9WgXcQ');
    expect(short?.videoId, 'dQw4w9WgXcQ');
  });

  test('parses playlist URLs into VL browse IDs', () {
    final link = codec.tryDecode(
      Uri.parse('https://music.youtube.com/playlist?list=PL1234567890abcdef'),
    );

    expect(link?.kind, YouTubeMusicLinkKind.playlist);
    expect(link?.playlistId, 'PL1234567890abcdef');
    expect(link?.collectionId, 'VLPL1234567890abcdef');
  });

  test('normalizes public and VL playlist routes to the same identity', () {
    final queryBrowse = codec.tryDecode(
      Uri.parse('https://music.youtube.com/playlist?list=VLPL1234567890abcdef'),
    );
    final pathBrowse = codec.tryDecode(
      Uri.parse('https://music.youtube.com/playlist/VLPL1234567890abcdef'),
    );
    final watchList = codec.tryDecode(
      Uri.parse('https://music.youtube.com/watch?list=PL1234567890abcdef'),
    );

    for (final link in <YouTubeMusicLink?>[
      queryBrowse,
      pathBrowse,
      watchList,
    ]) {
      expect(link?.kind, YouTubeMusicLinkKind.playlist);
      expect(link?.playlistId, 'PL1234567890abcdef');
      expect(link?.collectionId, 'VLPL1234567890abcdef');
    }
  });

  test('parses album and mix browse links', () {
    final album = codec.tryDecode(
      Uri.parse('https://music.youtube.com/browse/MPREb_abc123'),
    );
    final mix = codec.tryDecode(
      Uri.parse('https://music.youtube.com/browse/RDCLAK5uy_test'),
    );
    final radio = codec.tryDecode(
      Uri.parse('https://music.youtube.com/playlist?list=RDAMVMdQw4w9WgXcQ'),
    );
    final browseRadio = codec.tryDecode(
      Uri.parse('https://music.youtube.com/browse/VLRDAMVMdQw4w9WgXcQ'),
    );

    expect(album?.kind, YouTubeMusicLinkKind.album);
    expect(album?.collectionId, 'MPREb_abc123');
    expect(mix?.kind, YouTubeMusicLinkKind.mix);
    expect(mix?.collectionId, 'VLRDCLAK5uy_test');
    expect(radio?.kind, YouTubeMusicLinkKind.mix);
    expect(radio?.collectionId, 'VLRDAMVMdQw4w9WgXcQ');
    expect(browseRadio?.kind, YouTubeMusicLinkKind.mix);
    expect(browseRadio?.playlistId, 'RDAMVMdQw4w9WgXcQ');
    expect(browseRadio?.collectionId, 'VLRDAMVMdQw4w9WgXcQ');
  });

  test('playlist identity helpers never duplicate the VL browse prefix', () {
    expect(
      canonicalYouTubeMusicPlaylistId('VLPL1234567890abcdef'),
      'PL1234567890abcdef',
    );
    expect(
      youtubeMusicPlaylistBrowseId('VLPL1234567890abcdef'),
      'VLPL1234567890abcdef',
    );
    expect(
      youtubeMusicPlaylistBrowseId('PL1234567890abcdef'),
      'VLPL1234567890abcdef',
    );
    expect(canonicalYouTubeMusicPlaylistId('VL'), isNull);
  });

  test('rejects unsafe hosts, schemes, ports and malformed identities', () {
    expect(
      codec.tryDecode(
        Uri.parse('https://evil.youtube.com/watch?v=dQw4w9WgXcQ'),
      ),
      isNull,
    );
    expect(
      codec.tryDecode(
        Uri.parse('http://music.youtube.com/watch?v=dQw4w9WgXcQ'),
      ),
      isNull,
    );
    expect(
      codec.tryDecode(
        Uri.parse('https://music.youtube.com:8443/watch?v=dQw4w9WgXcQ'),
      ),
      isNull,
    );
    expect(
      codec.tryDecode(Uri.parse('https://youtube.com/watch?v=short')),
      isNull,
    );
  });
}
