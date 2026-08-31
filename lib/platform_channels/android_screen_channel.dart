import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';

class AndroidScreenChannel {
  const AndroidScreenChannel({MethodChannel? methodChannel})
    : _methodChannel =
          methodChannel ??
          const MethodChannel(AppConstants.androidScreenChannel);

  final MethodChannel _methodChannel;

  Future<void> setKeepScreenOn(bool enabled) async {
    try {
      await _methodChannel.invokeMethod<void>('setKeepScreenOn', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // The channel is Android-only; keep other platforms and old engines safe.
    } on PlatformException {
      // Failing to keep the display awake must not break the lyrics screen.
    }
  }

  Future<void> setStatusBarHidden(bool hidden) async {
    try {
      await _methodChannel.invokeMethod<void>('setStatusBarHidden', {
        'hidden': hidden,
      });
    } on MissingPluginException {
      // The channel is Android-only; keep other platforms and old engines safe.
    } on PlatformException {
      // A cosmetic system-bar failure must not break the lyrics screen.
    }
  }
}
