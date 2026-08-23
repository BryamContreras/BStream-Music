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

    expect(album?.kind, YouTubeMusicLinkKind.album);
    expect(album?.collectionId, 'MPREb_abc123');
    expect(mix?.kind, YouTubeMusicLinkKind.mix);
    expect(radio?.kind, YouTubeMusicLinkKind.mix);
    expect(radio?.collectionId, 'VLRDAMVMdQw4w9WgXcQ');
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
