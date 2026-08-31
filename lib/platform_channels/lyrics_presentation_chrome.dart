import 'package:flutter/foundation.dart';

import 'android_screen_channel.dart';

class LyricsPresentationChrome {
  const LyricsPresentationChrome({
    this.androidScreen = const AndroidScreenChannel(),
  });

  final AndroidScreenChannel androidScreen;

  Future<void> setSideModeActive({
    required TargetPlatform platform,
    required bool active,
  }) async {
    switch (platform) {
      case TargetPlatform.android:
        await androidScreen.setStatusBarHidden(active);
        return;
      case TargetPlatform.windows:
      case TargetPlatform.iOS:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.fuchsia:
        break;
    }
  }
}
