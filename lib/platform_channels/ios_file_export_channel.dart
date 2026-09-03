import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';

/// Presents iOS's document exporter without loading a potentially large
/// library backup into a platform-channel byte buffer.
class IosFileExportChannel {
  const IosFileExportChannel({MethodChannel? methodChannel})
    : _methodChannel =
          methodChannel ?? const MethodChannel(AppConstants.fileExportChannel);

  final MethodChannel _methodChannel;

  Future<String?> saveFile({
    required String sourcePath,
    required String fileName,
    String mimeType = 'application/zip',
  }) {
    return _methodChannel.invokeMethod<String>('saveFile', <String, Object>{
      'sourcePath': sourcePath,
      'fileName': fileName,
      'mimeType': mimeType,
    });
  }
}
