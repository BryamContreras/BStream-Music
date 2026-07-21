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
}
