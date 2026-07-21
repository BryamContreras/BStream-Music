import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';

class AndroidFileExportChannel {
  const AndroidFileExportChannel({MethodChannel? methodChannel})
    : _methodChannel =
          methodChannel ??
          const MethodChannel(AppConstants.androidFileExportChannel);

  final MethodChannel _methodChannel;

  Future<String?> saveFile({
    required String sourcePath,
    required String fileName,
    String mimeType = 'application/zip',
  }) {
    return _methodChannel.invokeMethod<String>('saveFile', {
      'sourcePath': sourcePath,
      'fileName': fileName,
      'mimeType': mimeType,
    });
  }
}
