import 'dart:io';

enum AppPlatformType { android, windows, macos, unsupported }

class AppPlatform {
  const AppPlatform._();

  static AppPlatformType get current {
    if (Platform.isAndroid) {
      return AppPlatformType.android;
    }
    if (Platform.isWindows) {
      return AppPlatformType.windows;
    }
    if (Platform.isMacOS) {
      return AppPlatformType.macos;
    }
    return AppPlatformType.unsupported;
  }

  static bool get isAndroid => current == AppPlatformType.android;

  static bool get isWindows => current == AppPlatformType.windows;

  static bool get isDesktop =>
      current == AppPlatformType.windows || current == AppPlatformType.macos;
}
