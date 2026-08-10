import 'dart:io';

import 'package:bstream_music/core/utils/image_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('converts file uri image sources to local files', () {
    final uri = Uri.file('/tmp/bstream-cover.jpg');

    expect(imageFileFromSource(uri.toString())?.path, File.fromUri(uri).path);
  });

  test('leaves network image sources out of local file handling', () {
    expect(isNetworkImageSource('https://example.com/cover.jpg'), isTrue);
    expect(imageFileFromSource('https://example.com/cover.jpg'), isNull);
  });

  test('normalizes YouTube thumbnail variants to the shared hq720 crop', () {
    expect(
      canonicalYouTubeThumbnailSource(
        'https://i.ytimg.com/vi/dmW68lzaaqs/maxresdefault.jpg?x=1',
      ),
      'https://i.ytimg.com/vi/dmW68lzaaqs/hq720.jpg',
    );
    expect(
      canonicalYouTubeThumbnailSource(
        'https://i.ytimg.com/vi_webp/dmW68lzaaqs/maxresdefault.webp',
      ),
      'https://i.ytimg.com/vi/dmW68lzaaqs/hq720.jpg',
    );
    expect(
      youtubeThumbnailSourceForVideoId('dmW68lzaaqs'),
      'https://i.ytimg.com/vi/dmW68lzaaqs/hq720.jpg',
    );
  });

  test('provides low-resolution fallbacks for older YouTube artwork', () {
    final candidates = youtubeThumbnailCandidates(
      'https://i.ytimg.com/vi/dmW68lzaaqs/hq720.jpg',
    );

    expect(candidates.first, 'https://i.ytimg.com/vi/dmW68lzaaqs/hq720.jpg');
    expect(
      candidates,
      containsAll(<String>[
        'https://i.ytimg.com/vi/dmW68lzaaqs/hqdefault.jpg',
        'https://i.ytimg.com/vi/dmW68lzaaqs/0.jpg',
      ]),
    );
    expect(youtubeVideoIdFromThumbnailSource(candidates.last), 'dmW68lzaaqs');
  });

  test('preserves non-YouTube and local artwork sources', () {
    expect(
      canonicalYouTubeThumbnailSource('https://example.com/cover.jpg'),
      'https://example.com/cover.jpg',
    );
    expect(
      canonicalYouTubeThumbnailSource('/tmp/bstream-cover.jpg'),
      '/tmp/bstream-cover.jpg',
    );
  });
}
