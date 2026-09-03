import 'dart:async';

/// Minimal, injectable JavaScript execution surface used by YouTube playback.
///
/// Implementations must keep the same global JavaScript context between calls.
/// This is required by both EJS (which installs its modules once) and BotGuard
/// (which keeps its PO-token minter in memory).
abstract interface class YoutubeJavaScriptRuntime {
  /// Starts the runtime and loads [html] as its initial document.
  ///
  /// Calling this method more than once must be harmless when the runtime is
  /// already initialized.
  Future<void> initialize({
    String html = YoutubeJavaScriptRuntime.emptyDocument,
    Uri? baseUrl,
  });

  /// Runs an async JavaScript function body in the current global context.
  ///
  /// Each key in [arguments] is exposed as a function parameter by the
  /// concrete runtime. Values must therefore be JSON-compatible.
  Future<Object?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const <String, dynamic>{},
    Duration? timeout,
  });

  Future<void> dispose();

  static const emptyDocument =
      '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>';
}

typedef YoutubeJavaScriptRuntimeFactory = YoutubeJavaScriptRuntime Function();

class YoutubeJavaScriptRuntimeException implements Exception {
  const YoutubeJavaScriptRuntimeException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'YoutubeJavaScriptRuntimeException: $message'
      : 'YoutubeJavaScriptRuntimeException: $message ($cause)';
}

class UnsupportedYoutubeJavaScriptRuntimeException
    extends YoutubeJavaScriptRuntimeException {
  const UnsupportedYoutubeJavaScriptRuntimeException(String platform)
    : super('Headless JavaScript playback is not supported on $platform.');
}
