import '../../core/platform/app_platform.dart';
import 'audio_service_desktop_media_session.dart';
import 'desktop_media_session.dart';
import 'windows_smtc_media_session.dart';

DesktopMediaSession createDesktopMediaSession() {
  return switch (AppPlatform.current) {
    AppPlatformType.windows => WindowsSmtcMediaSession(),
    AppPlatformType.linux ||
    AppPlatformType.macos => AudioServiceDesktopMediaSession(),
    _ => throw UnsupportedError(
      'Desktop media sessions are unavailable on this platform.',
    ),
  };
}
