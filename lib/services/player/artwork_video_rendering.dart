import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_win/video_player_win.dart';

import '../../core/platform/app_platform.dart';

/// Configure before creating any video controllers. Only the stock, unused
/// Windows backend is replaced; decoder operations remain inherited from it.
/// Medium filtering improves reduced artwork without another video pass.
void configureArtworkVideoRendering({AppPlatformType? platform}) {
  if ((platform ?? AppPlatform.current) != AppPlatformType.windows) return;
  final current = VideoPlayerPlatform.instance;
  if (current.runtimeType != WindowsVideoPlayer ||
      current is! WindowsVideoPlayer ||
      current.mControllerMap.isNotEmpty) {
    return;
  }
  VideoPlayerPlatform.instance = _ArtworkWindowsVideoPlayer();
}

class _ArtworkWindowsVideoPlayer extends WindowsVideoPlayer {
  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    final view = super.buildViewWithOptions(options);
    return view is WinVideoPlayer
        ? WinVideoPlayer(
            view.controller,
            key: view.key,
            filterQuality: FilterQuality.medium,
          )
        : view;
  }
}
