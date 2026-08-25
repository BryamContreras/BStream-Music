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

  test('round-trips lazy device audio artwork references', () {
    const audioUri =
        'content://media/external/audio/media/42?source=local music';
    final artwork = deviceAudioArtworkSourceForUri(audioUri);

    expect(isDeviceAudioArtworkSource(artwork), isTrue);
    expect(deviceAudioUriFromArtworkSource(artwork), audioUri);
    expect(
      deviceAudioUriFromArtworkSource('https://example.com/cover'),
      isNull,
    );
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

  test('requests a large Google catalog cover before the card-sized URL', () {
    const small =
        'https://lh3.googleusercontent.com/music-cover=w120-h120-l90-rj';
    const large =
        'https://lh3.googleusercontent.com/music-cover=w1280-h1280-l90-rj';

    expect(highResolutionGoogleArtworkSource(small), large);
    expect(artworkSourceCandidates(small), <String>[large, small]);
  });

  test('keeps the original CDN URL as fallback when it has no size suffix', () {
    const original = 'https://lh3.googleusercontent.com/music-cover';

    expect(artworkSourceCandidates(original), <String>[
      '$original=w1280-h1280-l90-rj',
      original,
    ]);
  });

  test('sizes Google artwork to stable scrolling and player buckets', () {
    const small =
        'https://yt3.googleusercontent.com/artist-photo=w120-h120-l90-rj';
    const large =
        'https://lh3.googleusercontent.com/album-cover=w1280-h1280-s-l90-rj';

    expect(
      sizedGoogleArtworkSource(small, 320),
      'https://yt3.googleusercontent.com/artist-photo=w384-h384-l90-rj',
    );
    expect(
      sizedGoogleArtworkSource(large, 512),
      'https://lh3.googleusercontent.com/album-cover=w640-h640-s-l90-rj',
    );
    expect(
      sizedGoogleArtworkSource('https://example.com/cover.jpg', 256),
      'https://example.com/cover.jpg',
    );
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
    expect(artworkSourceCandidates('https://example.com/cover.jpg'), [
      'https://example.com/cover.jpg',
    ]);
  });
}
