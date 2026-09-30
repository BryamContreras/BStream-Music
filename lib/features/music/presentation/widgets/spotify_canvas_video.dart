import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

@visibleForTesting
bool isRemoteArtworkVideoSizeAllowed(Size size) =>
    size.width > 0 &&
    size.height > 0 &&
    size.longestSide <= 1920 &&
    size.width * size.height <= 2200000;

/// Transparent until a decoded video frame exists. Keep the existing cover
/// underneath this widget so loading, offline and decoder errors are harmless.
class SpotifyCanvasVideo extends StatefulWidget {
  const SpotifyCanvasVideo({
    required this.url,
    required this.isPlaying,
    super.key,
  });

  final Uri url;
  final bool isPlaying;

  @override
  State<SpotifyCanvasVideo> createState() => _SpotifyCanvasVideoState();
}

class _SpotifyCanvasVideoState extends State<SpotifyCanvasVideo>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _active = true;
  bool _tickerEnabled = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    unawaited(_open());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _synchronizePlayback();
  }

  @override
  void didUpdateWidget(covariant SpotifyCanvasVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      unawaited(_open());
    } else if (oldWidget.isPlaying != widget.isPlaying) {
      _synchronizePlayback();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _synchronizePlayback();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    final previous = _controller;
    _controller = null;
    _ready = false;
    if (mounted) setState(() {});
    if (previous != null) unawaited(previous.dispose());

    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.networkUrl(
        widget.url,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _controller = controller;
      await controller.initialize().timeout(const Duration(seconds: 9));
      if (!mounted || generation != _generation) {
        await controller.dispose();
        return;
      }
      if (!isRemoteArtworkVideoSizeAllowed(controller.value.size)) {
        throw const FormatException('Artwork video exceeds display budget');
      }
      await controller.setVolume(0);
      await controller.setLooping(true);
      controller.addListener(_onVideoChanged);
      // Prime the first frame, even for a paused song. The still cover stays
      // visible until position advances and the texture is ready to paint.
      _synchronizePlayback();
    } catch (_) {
      if (generation == _generation) {
        _controller = null;
        if (mounted) setState(() => _ready = false);
      }
      if (controller != null) unawaited(controller.dispose());
    }
  }

  void _onVideoChanged() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    if (controller.value.hasError) {
      _controller = null;
      setState(() => _ready = false);
      unawaited(controller.dispose());
      return;
    }
    if (!_ready && controller.value.position > Duration.zero) {
      setState(() => _ready = true);
      _synchronizePlayback();
    }
  }

  void _synchronizePlayback() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (_active && _tickerEnabled && (!_ready || widget.isPlaying)) {
      unawaited(controller.play().catchError((_) {}));
    } else {
      unawaited(controller.pause().catchError((_) {}));
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final size = controller?.value.size ?? Size.zero;
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: _ready && size.width > 0 && size.height > 0 ? 1 : 0,
        child: controller == null || size.isEmpty
            ? const SizedBox.shrink()
            : ClipRect(
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: size.width,
                      height: size.height,
                      child: VideoPlayer(controller),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
