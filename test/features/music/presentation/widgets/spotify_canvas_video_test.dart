import 'package:bstream_music/features/music/presentation/widgets/spotify_canvas_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only portrait video receives the optional inset-artwork zoom', () {
    expect(effectivePortraitArtworkZoom(const Size(486, 648), 1.45), 1.45);
    expect(effectivePortraitArtworkZoom(const Size(768, 768), 1.45), 1.0);
    expect(effectivePortraitArtworkZoom(const Size(720, 1280), 1.0), 1.0);
    expect(effectivePortraitArtworkZoom(Size.zero, 1.45), 1.0);
  });

  test('accepts normal Canvas video sizes and rejects oversized frames', () {
    expect(isRemoteArtworkVideoSizeAllowed(const Size(720, 1280)), isTrue);
    expect(isRemoteArtworkVideoSizeAllowed(const Size(1080, 1920)), isTrue);
    expect(isRemoteArtworkVideoSizeAllowed(const Size(2160, 2160)), isFalse);
    expect(isRemoteArtworkVideoSizeAllowed(const Size(0, 720)), isFalse);
  });

  test('skips seven seconds only when artwork has enough video to loop', () {
    const skip = Duration(seconds: 7);
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 25)),
      skip,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 50)),
      skip,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 10)),
      skip,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 9)),
      Duration.zero,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 7)),
      Duration.zero,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 6)),
      Duration.zero,
    );
    expect(
      effectiveArtworkVideoStartOffset(
        skip,
        const Duration(milliseconds: 1),
        durationHint: const Duration(minutes: 2),
      ),
      skip,
    );
    expect(
      effectiveArtworkVideoStartOffset(
        skip,
        const Duration(milliseconds: 1),
        durationHint: const Duration(seconds: 6),
      ),
      Duration.zero,
    );
    expect(
      effectiveArtworkVideoStartOffset(
        Duration.zero,
        const Duration(seconds: 25),
      ),
      Duration.zero,
    );
  });
}
