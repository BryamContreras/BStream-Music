import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TikTok LIVE is available on every supported application platform', () {
    expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.android), isTrue);
    expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.windows), isTrue);
    expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.linux), isTrue);
    expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.macos), isTrue);
    expect(
      AppPlatform.supportsTikTokLiveOn(AppPlatformType.unsupported),
      isFalse,
    );
  });
}
