import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';

import '../../../../services/player/visual_load_diagnostics.dart';
import 'artwork_inset_detector.dart';

@visibleForTesting
bool isRemoteArtworkVideoSizeAllowed(Size size) =>
    size.width > 0 &&
    size.height > 0 &&
    size.longestSide <= 1920 &&
    size.width * size.height <= 2200000;

@visibleForTesting
Duration effectiveArtworkVideoStartOffset(
  Duration requested,
  Duration videoDuration, {
  Duration? durationHint,
}) {
  // Short clips must retain enough material for a useful loop.
  if (requested <= Duration.zero) {
    return Duration.zero;
  }
  final usableDuration = videoDuration > requested + const Duration(seconds: 2)
      ? videoDuration
      : durationHint ?? videoDuration;
  if (usableDuration <= requested + const Duration(seconds: 2)) {
    return Duration.zero;
  }
  return requested;
}

@visibleForTesting
double effectivePortraitArtworkZoom(Size videoSize, double requestedZoom) {
  // A square fallback must not inherit the crop intended for an inset
  // portrait master. Leave full-bleed videos unchanged at the call site.
  if (requestedZoom <= 1 ||
      videoSize.isEmpty ||
      videoSize.width / videoSize.height >= 0.9) {
    return 1.0;
  }
  return requestedZoom;
}

/// Transparent until a decoded video frame exists. Keep the existing cover
/// underneath this widget so loading, offline and decoder errors are harmless.
class SpotifyCanvasVideo extends StatefulWidget {
  const SpotifyCanvasVideo({
    required this.url,
    required this.isPlaying,
    this.identity,
    this.startOffset = Duration.zero,
    this.durationHint = Duration.zero,
    this.autoFitInsetArtwork = false,
    this.coverPath,
    super.key,
  });

  final Uri url;
  final bool isPlaying;
  final String? identity;
  final Duration startOffset;
  final Duration durationHint;
  final bool autoFitInsetArtwork;
  final String? coverPath;

  @override
  State<SpotifyCanvasVideo> createState() => _SpotifyCanvasVideoState();
}

class _SpotifyCanvasVideoState extends State<SpotifyCanvasVideo>
    with WidgetsBindingObserver {
  static const _introFastForwardSpeed = 8.0;
  static const _videoRevealDuration = Duration(milliseconds: 250);
  static const _loopFrameCrossfadeDuration = Duration(milliseconds: 400);
  static const _loopFrameHoldBeforeFade = Duration(milliseconds: 100);
  static const _loopFrameDecodeGuard = Duration(milliseconds: 120);
  static const _loopFrameMaxSide = 480.0;
  static const _insetProbeMaxSide = 192.0;
  static final LinkedHashMap<String, double> _insetZoomCache = LinkedHashMap();

  VideoPlayerController? _controller;
  final GlobalKey _videoFrameBoundaryKey = GlobalKey();
  ui.Image? _loopFrame;
  bool _loopFrameFadingOut = false;
  bool _loopFrameCaptureUnavailable = false;
  Timer? _loopFrameFadeTimer;
  Timer? _loopFrameReleaseTimer;
  bool _ready = false;
  bool _active = true;
  bool _tickerEnabled = true;
  int _generation = 0;
  int _loopRestartToken = 0;
  Duration _effectiveStartOffset = Duration.zero;
  bool _restartingLoop = false;
  bool _recoveringLateCompletion = false;
  bool _loopRestartSeekIssued = false;
  bool _loopRestartPending = false;
  bool _loopHasAdvancedSinceRestart = false;
  bool _fastForwardingIntro = false;
  bool _insetFitAttempted = false;
  bool _insetFitResolved = true;
  double _insetZoom = 1;
  final Stopwatch _startupTimer = Stopwatch();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _resetInsetFit();
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
    if (oldWidget.url != widget.url ||
        oldWidget.startOffset != widget.startOffset) {
      unawaited(_open());
    } else {
      if (oldWidget.coverPath != widget.coverPath ||
          oldWidget.autoFitInsetArtwork != widget.autoFitInsetArtwork) {
        _resetInsetFit(keepVisible: _ready);
        _queueInsetFitAnalysis();
      }
      if (oldWidget.isPlaying != widget.isPlaying) _synchronizePlayback();
    }
  }

  String? get _insetCacheKey {
    if (!widget.autoFitInsetArtwork) return null;
    return '${widget.url}|${widget.coverPath}';
  }

  void _resetInsetFit({bool keepVisible = false}) {
    final key = _insetCacheKey;
    final cachedZoom = key == null ? null : _insetZoomCache[key];
    _insetZoom = cachedZoom ?? 1;
    _insetFitResolved = keepVisible || cachedZoom != null || key == null;
    _insetFitAttempted = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _synchronizePlayback();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    _startupTimer
      ..reset()
      ..start();
    logVisualLoad(
      'video decoder opening',
      track: widget.identity ?? widget.url.toString(),
    );
    final previous = _controller;
    _controller = null;
    _ready = false;
    _clearLoopFrame();
    _effectiveStartOffset = Duration.zero;
    _loopRestartToken++;
    _restartingLoop = false;
    _recoveringLateCompletion = false;
    _loopRestartSeekIssued = false;
    _loopRestartPending = false;
    _loopHasAdvancedSinceRestart = false;
    _fastForwardingIntro = false;
    _loopFrameCaptureUnavailable = false;
    _resetInsetFit();
    if (mounted) setState(() {});
    if (previous != null) unawaited(previous.dispose());

    VideoPlayerController? controller;
    try {
      // The player cache hands us only completed local media. Keeping the
      // decoder off the network also makes a track switch stop the old fetch.
      controller = widget.url.scheme == 'file'
          ? VideoPlayerController.file(
              File.fromUri(widget.url),
              videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
            )
          : VideoPlayerController.networkUrl(
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
      logVisualLoad(
        'video decoder initialized',
        track: widget.identity ?? widget.url.toString(),
        elapsedMs: _startupTimer.elapsedMilliseconds,
      );
      await controller.setVolume(0);
      final startOffset = effectiveArtworkVideoStartOffset(
        widget.startOffset,
        controller.value.duration,
        durationHint: widget.durationHint,
      );
      _effectiveStartOffset = startOffset;
      if (startOffset > Duration.zero &&
          controller.value.duration <=
              startOffset + const Duration(seconds: 2) &&
          widget.durationHint > startOffset + const Duration(seconds: 2)) {
        // Fragmented MP4 artwork can omit its total duration. Use the known
        // song duration as the controller's seek bound; the native decoder
        // still clamps to the clip's actual end.
        controller.value = controller.value.copyWith(
          duration: widget.durationHint,
        );
      }
      logVisualLoad(
        'video timeline requested=${widget.startOffset.inMilliseconds}ms effective=${startOffset.inMilliseconds}ms duration=${controller.value.duration.inMilliseconds}ms hint=${widget.durationHint.inMilliseconds}ms',
        track: widget.identity ?? widget.url.toString(),
      );
      await controller.setLooping(startOffset == Duration.zero);
      if (startOffset > Duration.zero) {
        // Start the muted decoder before seeking. Some platform players can
        // defer a seek issued while newly initialized and paused, then decode
        // from zero when play() is first called. The still cover hides those
        // priming frames until the video reaches the requested offset.
        if (_active && _tickerEnabled) {
          await controller.play();
        }
        await controller.seekTo(startOffset);
        if (!mounted || generation != _generation) {
          await controller.dispose();
          return;
        }
        logVisualLoad(
          'video intro seek requested',
          track: widget.identity ?? widget.url.toString(),
          elapsedMs: startOffset.inMilliseconds,
        );
      }
      controller.addListener(_onVideoChanged);
      // Prime the first frame, even for a paused song. The still cover stays
      // visible until position advances and the texture is ready to paint.
      _synchronizePlayback();
    } catch (_) {
      if (generation == _generation) {
        logVisualLoad(
          'video decoder failed',
          track: widget.identity ?? widget.url.toString(),
          elapsedMs: _startupTimer.elapsedMilliseconds,
        );
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
    if (_effectiveStartOffset > Duration.zero && controller.value.isCompleted) {
      if (_restartingLoop) {
        // The video_player plugin also seeks to the end when it receives its
        // completion event. If that seek wins a race against our loop seek,
        // remember it and run the intro skip once the current restart settles.
        if (_loopRestartSeekIssued) {
          _loopRestartPending = true;
          if (_ready && _loopFrame != null) {
            _loopFrameFadeTimer?.cancel();
            _loopFrameReleaseTimer?.cancel();
            setState(() {
              _ready = false;
              _loopFrameFadingOut = false;
            });
          }
        }
      } else if (_recoveringLateCompletion) {
        // Ignore duplicate completion notifications while recovering the
        // plugin's delayed end seek.
      } else if (!_loopHasAdvancedSinceRestart) {
        // video_player can publish its completion state before its own final
        // seek has settled. If the restarted clip has not shown a post-offset
        // frame yet, this is that stale event—not another artwork loop.
        unawaited(_recoverLateCompletion(controller, _generation));
      } else {
        unawaited(_restartArtworkLoop(controller, _generation));
      }
      return;
    }
    final position = controller.value.position;
    final firstRenderablePosition = _effectiveStartOffset > Duration.zero
        ? _effectiveStartOffset + _loopFrameDecodeGuard
        : _effectiveStartOffset;
    if (_effectiveStartOffset > Duration.zero &&
        position > firstRenderablePosition) {
      _loopHasAdvancedSinceRestart = true;
    }
    if (_fastForwardingIntro && position > _effectiveStartOffset) {
      _fastForwardingIntro = false;
      _loopFrameCaptureUnavailable = false;
      unawaited(controller.setPlaybackSpeed(1).catchError((_) {}));
    }
    if (_loopFrameCaptureUnavailable &&
        controller.value.isPlaying &&
        position <= _effectiveStartOffset &&
        !_fastForwardingIntro) {
      // If this renderer cannot snapshot its external video texture, keep the
      // moving surface visible and compress the hidden intro to avoid flashing
      // the still cover beneath it.
      _fastForwardingIntro = true;
      unawaited(
        controller.setPlaybackSpeed(_introFastForwardSpeed).catchError((_) {}),
      );
    }
    if (!_ready) {
      if (position > firstRenderablePosition) {
        logVisualLoad(
          'video first advancing frame',
          track: widget.identity ?? widget.url.toString(),
          elapsedMs: _startupTimer.elapsedMilliseconds,
        );
        setState(() => _ready = true);
        _queueInsetFitAnalysis();
        _scheduleLoopFrameRelease();
        _synchronizePlayback();
      } else if (_effectiveStartOffset > Duration.zero &&
          controller.value.isPlaying &&
          !_fastForwardingIntro) {
        // Fragmented MP4 artwork can be playable but not seekable. If the
        // native player starts at zero after the seek, advance the muted
        // decoder quickly behind the still cover until it reaches 5 seconds.
        _fastForwardingIntro = true;
        logVisualLoad(
          'video intro seek unavailable; fast-forwarding',
          track: widget.identity ?? widget.url.toString(),
        );
        unawaited(
          controller
              .setPlaybackSpeed(_introFastForwardSpeed)
              .catchError((_) {}),
        );
      }
    }
  }

  Future<void> _restartArtworkLoop(
    VideoPlayerController controller,
    int generation,
  ) async {
    if (_restartingLoop) {
      _loopRestartPending = true;
      return;
    }
    final restartToken = ++_loopRestartToken;
    _restartingLoop = true;
    _loopRestartSeekIssued = false;
    _loopRestartPending = false;
    _fastForwardingIntro = false;
    _loopHasAdvancedSinceRestart = false;
    try {
      // The plugin schedules its own pause and end-frame seek on completion.
      // Wait for that end seek before returning to the artwork's intro offset.
      // A bounded wait keeps unusual platform implementations from stalling.
      await controller.pause();
      if (!mounted ||
          generation != _generation ||
          !identical(_controller, controller)) {
        return;
      }
      final heldFrame = await _captureLoopFrame();
      if (!mounted ||
          generation != _generation ||
          !identical(_controller, controller)) {
        heldFrame?.dispose();
        return;
      }
      if (heldFrame != null) {
        _loopFrameFadeTimer?.cancel();
        _loopFrameReleaseTimer?.cancel();
        final previousFrame = _loopFrame;
        setState(() {
          _loopFrame = heldFrame;
          _loopFrameFadingOut = false;
          _loopFrameCaptureUnavailable = false;
          _ready = false;
        });
        if (previousFrame != null) _disposeAfterFrame(previousFrame);
        logVisualLoad(
          'video loop frame held',
          track: widget.identity ?? widget.url.toString(),
        );
      } else {
        logVisualLoad(
          'video loop frame capture unavailable',
          track: widget.identity ?? widget.url.toString(),
        );
        _loopFrameCaptureUnavailable = true;
      }
      await controller.setPlaybackSpeed(1);
      final endSeekSettled = await _waitForCompletionEndSeek(controller);
      if (!endSeekSettled) {
        logVisualLoad(
          'video loop end seek did not settle before timeout',
          track: widget.identity ?? widget.url.toString(),
        );
      }
      if (!mounted ||
          generation != _generation ||
          !identical(_controller, controller)) {
        return;
      }
      _loopRestartSeekIssued = true;
      await controller.seekTo(_effectiveStartOffset);
      if (mounted &&
          generation == _generation &&
          identical(_controller, controller) &&
          restartToken == _loopRestartToken) {
        logVisualLoad(
          'video artwork loop restarted',
          track: widget.identity ?? widget.url.toString(),
        );
        _synchronizePlayback();
      }
    } catch (_) {
      // The still cover remains available if the decoder cannot seek.
    } finally {
      if (restartToken == _loopRestartToken) {
        final restartAgain =
            _loopRestartPending &&
            mounted &&
            generation == _generation &&
            identical(_controller, controller);
        _restartingLoop = false;
        _loopRestartSeekIssued = false;
        _loopRestartPending = false;
        if (restartAgain) {
          scheduleMicrotask(() {
            if (mounted &&
                generation == _generation &&
                identical(_controller, controller)) {
              unawaited(_recoverLateCompletion(controller, generation));
            }
          });
        }
      }
    }
  }

  Future<void> _recoverLateCompletion(
    VideoPlayerController controller,
    int generation,
  ) async {
    if (_recoveringLateCompletion || _restartingLoop) return;
    _recoveringLateCompletion = true;
    try {
      // Re-seek the same loop's intro without recapturing or briefly exposing
      // a new still frame. The plugin's completion pause was queued first.
      await controller.pause();
      if (!mounted ||
          generation != _generation ||
          !identical(_controller, controller)) {
        return;
      }
      await controller.seekTo(_effectiveStartOffset);
      if (!mounted ||
          generation != _generation ||
          !identical(_controller, controller)) {
        return;
      }
      _fastForwardingIntro = false;
      logVisualLoad(
        'video stale completion recovered without recapturing frame',
        track: widget.identity ?? widget.url.toString(),
      );
      _synchronizePlayback();
    } catch (_) {
      // Keep the held frame or live surface; the still cover is not revealed.
    } finally {
      _recoveringLateCompletion = false;
    }
  }

  void _queueInsetFitAnalysis() {
    final controller = _controller;
    final key = _insetCacheKey;
    if (!_ready || controller == null || key == null || _insetFitAttempted) {
      return;
    }
    if (controller.value.size.width / controller.value.size.height >= 0.9) {
      _insetFitResolved = true;
      return;
    }
    _insetFitAttempted = true;
    final generation = _generation;
    final coverPath = widget.coverPath;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation && key == _insetCacheKey) {
        unawaited(_resolveInsetFit(generation, key, coverPath));
      }
    });
  }

  Future<void> _resolveInsetFit(
    int generation,
    String cacheKey,
    String? coverPath,
  ) async {
    var frame = await _captureInsetProbeFrame();
    if (frame == null) {
      // Some texture renderers need one more presented frame before a
      // screenshot contains video. Do not retry continuously during playback.
      await Future<void>.delayed(const Duration(milliseconds: 90));
      frame = await _captureInsetProbeFrame();
    }
    final cover = frame == null || coverPath == null
        ? null
        : await _decodeCachedCover(coverPath);
    if (!mounted || generation != _generation || cacheKey != _insetCacheKey) {
      return;
    }
    final zoom = frame == null
        ? 1.0
        : detectArtworkInsetZoom(video: frame, cover: cover);
    if (frame != null) {
      _insetZoomCache.remove(cacheKey);
      _insetZoomCache[cacheKey] = zoom;
      while (_insetZoomCache.length > 24) {
        _insetZoomCache.remove(_insetZoomCache.keys.first);
      }
    }
    logVisualLoad(
      'video inset fit ${zoom.toStringAsFixed(2)}x',
      track: widget.identity ?? widget.url.toString(),
    );
    setState(() {
      _insetZoom = zoom;
      _insetFitResolved = true;
    });
  }

  Future<ArtworkInsetFrame?> _captureInsetProbeFrame() async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await WidgetsBinding.instance.endOfFrame;
      final renderObject = _videoFrameBoundaryKey.currentContext
          ?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary ||
          renderObject.debugNeedsPaint ||
          renderObject.size.isEmpty) {
        return null;
      }
      final image = await renderObject.toImage(
        pixelRatio: math.min(
          1,
          _insetProbeMaxSide / renderObject.size.longestSide,
        ),
      );
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) return null;
        final center =
            ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
        if (data.getUint8(center + 3) < 240) return null;
        var darkest = 255;
        var lightest = 0;
        for (var y = 1; y <= 5; y++) {
          for (var x = 1; x <= 5; x++) {
            final pixel =
                ((image.height * y ~/ 6) * image.width + image.width * x ~/ 6) *
                4;
            final brightness =
                (data.getUint8(pixel) +
                    data.getUint8(pixel + 1) +
                    data.getUint8(pixel + 2)) ~/
                3;
            darkest = math.min(darkest, brightness);
            lightest = math.max(lightest, brightness);
          }
        }
        if (lightest - darkest < 12) return null;
        return ArtworkInsetFrame(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          image.width,
          image.height,
        );
      } finally {
        image.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  Future<ArtworkInsetFrame?> _decodeCachedCover(String path) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      // The visual cache has already downloaded this file. Decode only a
      // thumbnail for the one-time comparison; never start a second fetch.
      final file = File(path);
      if (await file.length() > 4 * 1024 * 1024) return null;
      final bytes = await file.readAsBytes();
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 96);
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return ArtworkInsetFrame(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        image.width,
        image.height,
      );
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  Future<ui.Image?> _captureLoopFrame() async {
    try {
      await WidgetsBinding.instance.endOfFrame;
      final renderObject = _videoFrameBoundaryKey.currentContext
          ?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary ||
          renderObject.debugNeedsPaint ||
          renderObject.size.isEmpty) {
        return null;
      }
      final pixelRatio = math.min(
        1.0,
        _loopFrameMaxSide / renderObject.size.longestSide,
      );
      final image = await renderObject.toImage(pixelRatio: pixelRatio);
      final pixelData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (pixelData == null) {
        image.dispose();
        return null;
      }
      final centerPixel =
          ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      final centerAlpha = pixelData.getUint8(centerPixel + 3);
      logVisualLoad(
        'video loop frame captured ${image.width}x${image.height} centerAlpha=$centerAlpha',
        track: widget.identity ?? widget.url.toString(),
      );
      if (centerAlpha < 240) {
        image.dispose();
        return null;
      }
      return image;
    } catch (_) {
      return null;
    }
  }

  void _scheduleLoopFrameRelease() {
    final frame = _loopFrame;
    if (frame == null) return;
    _loopFrameFadeTimer?.cancel();
    _loopFrameReleaseTimer?.cancel();
    _loopFrameFadingOut = false;
    _loopFrameFadeTimer = Timer(_loopFrameHoldBeforeFade, () {
      if (!identical(_loopFrame, frame) || !mounted || !_ready) return;
      setState(() => _loopFrameFadingOut = true);
      _loopFrameReleaseTimer = Timer(
        _loopFrameCrossfadeDuration + const Duration(milliseconds: 50),
        () {
          if (!identical(_loopFrame, frame)) return;
          if (!mounted) {
            _loopFrame = null;
            frame.dispose();
            return;
          }
          setState(() => _loopFrame = null);
          _disposeAfterFrame(frame);
        },
      );
    });
  }

  void _clearLoopFrame() {
    _loopFrameFadeTimer?.cancel();
    _loopFrameFadeTimer = null;
    _loopFrameReleaseTimer?.cancel();
    _loopFrameReleaseTimer = null;
    final frame = _loopFrame;
    _loopFrame = null;
    _loopFrameFadingOut = false;
    if (frame != null) _disposeAfterFrame(frame);
  }

  void _disposeAfterFrame(ui.Image frame) {
    WidgetsBinding.instance.addPostFrameCallback((_) => frame.dispose());
  }

  Future<bool> _waitForCompletionEndSeek(
    VideoPlayerController controller,
  ) async {
    bool reachedEnd() =>
        controller.value.isCompleted &&
        controller.value.position >= controller.value.duration;

    if (reachedEnd()) return true;
    final settled = Completer<void>();
    void observe() {
      if (!settled.isCompleted && reachedEnd()) settled.complete();
    }

    controller.addListener(observe);
    try {
      observe();
      await settled.future.timeout(const Duration(milliseconds: 250));
      return true;
    } on TimeoutException {
      return false;
    } finally {
      controller.removeListener(observe);
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
    _loopFrameFadeTimer?.cancel();
    _loopFrameReleaseTimer?.cancel();
    _loopFrame?.dispose();
    _loopFrame = null;
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
    final zoom = effectivePortraitArtworkZoom(size, _insetZoom);
    final frames = Stack(
      fit: StackFit.expand,
      children: [
        AnimatedOpacity(
          duration: _loopFrame != null && !_ready
              ? Duration.zero
              : _loopFrame != null
              ? _loopFrameCrossfadeDuration
              : _videoRevealDuration,
          curve: _loopFrame != null ? Curves.easeInOutCubic : Curves.linear,
          // Paint at a barely visible opacity while comparing the first
          // frame, then reveal the already fitted video over the still cover.
          opacity: _ready && size.width > 0 && size.height > 0
              ? (_insetFitResolved ? 1 : 0.02)
              : 0,
          child: controller == null || size.isEmpty
              ? const SizedBox.shrink()
              : RepaintBoundary(
                  key: _videoFrameBoundaryKey,
                  child: ClipRect(
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
        ),
        if (_loopFrame case final frame?)
          AnimatedOpacity(
            duration: _loopFrameFadingOut
                ? _loopFrameCrossfadeDuration
                : Duration.zero,
            curve: Curves.easeInOutCubic,
            opacity: _loopFrameFadingOut ? 0 : 1,
            child: RawImage(
              image: frame,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
            ),
          ),
      ],
    );
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: zoom),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        child: frames,
        builder: (context, scale, child) => scale <= 1
            ? child!
            : ClipRect(
                child: Transform.scale(
                  scale: scale,
                  // Preserve the top of an inset square when magnifying it.
                  alignment: const Alignment(0, -0.2),
                  child: child,
                ),
              ),
      ),
    );
  }
}
