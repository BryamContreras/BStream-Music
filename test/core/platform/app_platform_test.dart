import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TikTok LIVE is available on every supported application platform', () {
    expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.android), isTrue);
    expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.ios), isTrue);
    expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.windows), isTrue);
    expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.linux), isTrue);
    expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.macos), isTrue);
    expect(
      AppPlatform.supportsTikTokLiveOn(AppPlatformType.unsupported),
      isFalse,
    );
  });

  test('mobile helpers classify Android and iOS without including desktop', () {
    expect(AppPlatform.isMobileOn(AppPlatformType.android), isTrue);
    expect(AppPlatform.isMobileOn(AppPlatformType.ios), isTrue);
    expect(AppPlatform.isMobileOn(AppPlatformType.windows), isFalse);
    expect(AppPlatform.isMobileOn(AppPlatformType.linux), isFalse);
    expect(AppPlatform.isMobileOn(AppPlatformType.macos), isFalse);
    expect(AppPlatform.isMobileOn(AppPlatformType.unsupported), isFalse);

    expect(AppPlatform.isMobileTargetPlatform(TargetPlatform.android), isTrue);
    expect(AppPlatform.isMobileTargetPlatform(TargetPlatform.iOS), isTrue);
    expect(AppPlatform.isMobileTargetPlatform(TargetPlatform.macOS), isFalse);
  });
}
