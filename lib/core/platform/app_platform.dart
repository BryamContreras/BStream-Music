import 'dart:io';

import 'package:flutter/foundation.dart';

enum AppPlatformType { android, ios, windows, linux, macos, unsupported }

class AppPlatform {
  const AppPlatform._();

  static AppPlatformType get current {
    if (Platform.isAndroid) {
      return AppPlatformType.android;
    }
    if (Platform.isIOS) {
      return AppPlatformType.ios;
    }
    if (Platform.isWindows) {
      return AppPlatformType.windows;
    }
    if (Platform.isLinux) {
      return AppPlatformType.linux;
    }
    if (Platform.isMacOS) {
      return AppPlatformType.macos;
    }
    return AppPlatformType.unsupported;
  }

  static bool get isAndroid => current == AppPlatformType.android;

  static bool get isIOS => current == AppPlatformType.ios;

  static bool get isWindows => current == AppPlatformType.windows;

  static bool get isLinux => current == AppPlatformType.linux;

  static bool get isMobile => isMobileOn(current);

  static bool isMobileOn(AppPlatformType platform) =>
      platform == AppPlatformType.android || platform == AppPlatformType.ios;

  static bool isMobileTargetPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;

  /// Platforms where the in-process Dart TikTok LIVE transport is exposed.
  ///
  /// The TikTok LIVE client uses `dart:io` HTTP/TLS/WebSocket primitives and
  /// does not depend on a platform plugin or companion executable.
  static bool get supportsTikTokLive => supportsTikTokLiveOn(current);

  static bool supportsTikTokLiveOn(AppPlatformType platform) =>
      platform == AppPlatformType.android ||
      platform == AppPlatformType.ios ||
      platform == AppPlatformType.windows ||
      platform == AppPlatformType.linux ||
      platform == AppPlatformType.macos;

  static bool get isDesktop =>
      current == AppPlatformType.windows ||
      current == AppPlatformType.linux ||
      current == AppPlatformType.macos;
}
