import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';

class AndroidSupportedLinksSettingsChannel {
  const AndroidSupportedLinksSettingsChannel({MethodChannel? methodChannel})
    : _methodChannel =
          methodChannel ??
          const MethodChannel(
            AppConstants.androidSupportedLinksSettingsChannel,
          );

  final MethodChannel _methodChannel;

  Future<bool> open() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'openSupportedLinksSettings',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
