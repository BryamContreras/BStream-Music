import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform_channels/desktop_window_channel.dart';

/// App-wide, including routes and text fields that have their own focus nodes.
class DesktopWindowShortcuts extends StatefulWidget {
  const DesktopWindowShortcuts({
    super.key,
    required this.child,
    this.windowChannel = const DesktopWindowChannel(),
  });

  final Widget child;
  final DesktopWindowChannel windowChannel;

  @override
  State<DesktopWindowShortcuts> createState() => _DesktopWindowShortcutsState();
}

class _DesktopWindowShortcutsState extends State<DesktopWindowShortcuts> {
  bool _desktop = false;
  bool _togglePending = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _desktop =
        !kIsWeb &&
        switch (Theme.of(context).platform) {
          TargetPlatform.windows ||
          TargetPlatform.linux ||
          TargetPlatform.macOS => true,
          _ => false,
        };
  }

  bool _handleKey(KeyEvent event) {
    if (!_desktop || event.logicalKey != LogicalKeyboardKey.f11) {
      return false;
    }
    // Holding F11 must not repeatedly enter and leave fullscreen.
    if (event is KeyDownEvent && !_togglePending) {
      unawaited(_toggleFullScreen());
    }
    return true;
  }

  Future<void> _toggleFullScreen() async {
    _togglePending = true;
    try {
      await widget.windowChannel.toggleFullScreen();
    } on MissingPluginException {
      // Older/custom runners may not expose window control.
    } on PlatformException catch (error) {
      debugPrint('Unable to toggle fullscreen: ${error.code}');
    } finally {
      _togglePending = false;
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
