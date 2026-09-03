import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/media_session/audio_service_desktop_media_session.dart';
import 'package:bstream_music/services/media_session/desktop_media_session_factory.dart';
import 'package:bstream_music/services/media_session/windows_smtc_media_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS uses the audio_service media session implementation', () {
    expect(
      createDesktopMediaSession(platform: AppPlatformType.ios),
      isA<AudioServiceDesktopMediaSession>(),
    );
  });

  test('existing platform media-session mappings remain unchanged', () {
    expect(
      createDesktopMediaSession(platform: AppPlatformType.android),
      isA<AudioServiceDesktopMediaSession>(),
    );
    expect(
      createDesktopMediaSession(platform: AppPlatformType.windows),
      isA<WindowsSmtcMediaSession>(),
    );
    expect(
      createDesktopMediaSession(platform: AppPlatformType.linux),
      isA<AudioServiceDesktopMediaSession>(),
    );
    expect(
      createDesktopMediaSession(platform: AppPlatformType.macos),
      isA<AudioServiceDesktopMediaSession>(),
    );
  });

  test('unsupported platforms still fail explicitly', () {
    expect(
      () => createDesktopMediaSession(platform: AppPlatformType.unsupported),
      throwsUnsupportedError,
    );
  });
}
