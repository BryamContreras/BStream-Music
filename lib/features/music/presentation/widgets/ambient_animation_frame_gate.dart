import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Keeps decorative player animation near 60 fps on high-refresh displays.
/// Playback controls and route transitions still use the display's full rate.
class AmbientAnimationFrameGate extends ChangeNotifier {
  AmbientAnimationFrameGate(Listenable source) : _source = source {
    _source.addListener(_onSourceTick);
  }

  final Listenable _source;
  Duration? _lastFrameStamp;
  int _frameIndex = 0;
  int _stride = 1;

  void setDisplayRefreshRate(double hertz) {
    final safeRate = hertz.isFinite && hertz > 0 ? hertz : 60.0;
    // 90 Hz keeps its native cadence. 120/144 Hz use every second frame;
    // 180/240 Hz use every third/fourth frame respectively.
    final stride = ((safeRate + 2) / 60).floor().clamp(1, 4);
    if (stride == _stride) return;
    _stride = stride;
    _frameIndex = 0;
    _lastFrameStamp = null;
    notifyListeners();
  }

  void _onSourceTick() {
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.idle) {
      // A controller can reset synchronously on pause or app suspension.
      // Paint that final pose immediately; no vsync timestamp exists here.
      _lastFrameStamp = null;
      notifyListeners();
      return;
    }
    // Zoom, pan and depth can all notify during the same vsync. Count that
    // display frame once so their phases remain synchronized in the picture.
    final stamp = scheduler.currentFrameTimeStamp;
    if (stamp == _lastFrameStamp) return;
    _lastFrameStamp = stamp;
    if (_frameIndex++ % _stride == 0) notifyListeners();
  }

  @override
  void dispose() {
    _source.removeListener(_onSourceTick);
    super.dispose();
  }
}
