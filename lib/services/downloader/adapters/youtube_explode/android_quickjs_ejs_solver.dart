import 'package:youtube_explode_dart/js_challenge.dart';

import '../../../../platform_channels/android_ytdl_channel.dart';

/// Runs youtube_explode_dart EJS calls through the QuickJS binary already
/// packaged by youtubedl-android.
class AndroidQuickJsEjsSolver extends BaseEJSSolver {
  AndroidQuickJsEjsSolver({
    AndroidYtdlChannel? channel,
    this.executionTimeout = const Duration(seconds: 15),
    Future<String> Function()? modulesLoader,
  }) : _channel = channel ?? AndroidYtdlChannel(),
       _modulesLoader = modulesLoader ?? EJSBuilder.getJSModules {
    if (executionTimeout <= Duration.zero) {
      throw ArgumentError.value(
        executionTimeout,
        'executionTimeout',
        'Must be positive.',
      );
    }
  }

  final AndroidYtdlChannel _channel;
  final Duration executionTimeout;
  final Future<String> Function() _modulesLoader;
  Future<String>? _modulesFuture;

  @override
  Future<String> executeJavaScript(String jsCode) async {
    try {
      final modules = _modulesFuture ??= _modulesLoader();
      final script = '${await modules}\nconsole.log($jsCode);';
      return await _channel.executeJavaScript(
        script,
        timeout: executionTimeout,
      );
    } catch (_) {
      _modulesFuture = null;
      rethrow;
    }
  }
}
