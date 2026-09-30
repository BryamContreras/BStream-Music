import 'package:bstream_music/features/music/presentation/widgets/spotify_canvas_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts normal Canvas video sizes and rejects oversized frames', () {
    expect(isRemoteArtworkVideoSizeAllowed(const Size(720, 1280)), isTrue);
    expect(isRemoteArtworkVideoSizeAllowed(const Size(1080, 1920)), isTrue);
    expect(isRemoteArtworkVideoSizeAllowed(const Size(2160, 2160)), isFalse);
    expect(isRemoteArtworkVideoSizeAllowed(const Size(0, 720)), isFalse);
  });
}
