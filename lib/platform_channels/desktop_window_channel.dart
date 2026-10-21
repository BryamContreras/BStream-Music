import 'package:flutter/services.dart';

/// Uses the native window manager so leaving fullscreen restores the previous
/// window bounds/maximized state, rather than just hiding Flutter's chrome.
class DesktopWindowChannel {
  const DesktopWindowChannel({
    this.methodChannel = const MethodChannel('bstream/desktop_window'),
  });

  final MethodChannel methodChannel;

  Future<void> toggleFullScreen() =>
      methodChannel.invokeMethod<void>('toggleFullScreen');
}
