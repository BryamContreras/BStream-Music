import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/cached_artwork_image_provider.dart';
import '../../../../core/utils/image_source.dart';

/// Shared colors used by artwork-tinted playback progress indicators.
abstract final class ArtworkProgressColor {
  static const fallback = Color(0xFF91CDA7);
}

/// One cancellable claim on a shared artwork-color lookup.
///
/// Releasing a lease is idempotent. The underlying image load remains alive
/// while another lease (or a direct [ArtworkProgressColorService.resolve]
/// caller) still needs the same source.
class ArtworkProgressColorLease {
  ArtworkProgressColorLease({required this.future});

  ArtworkProgressColorLease._({required this.future, required this._onRelease});

  final Future<Color> future;
  VoidCallback? _onRelease;

  void release() {
    final onRelease = _onRelease;
    _onRelease = null;
    onRelease?.call();
  }
}

/// Resolves and caches the playback progress color for an artwork source.
///
/// Concurrent requests for the same source share one image load and extraction.
/// Extracted colors are kept in a small LRU cache so the full player and mini
/// player do not sample the same artwork independently.
class ArtworkProgressColorService {
  ArtworkProgressColorService({
    this.maximumCacheEntries = 32,
    this.imageLoadTimeout = const Duration(seconds: 20),
    this.imageProviderForSource,
  }) : assert(maximumCacheEntries > 0),
       assert(imageLoadTimeout > Duration.zero);

  final int maximumCacheEntries;
  final Duration imageLoadTimeout;
  @visibleForTesting
  final ImageProvider<Object>? Function(String source)? imageProviderForSource;
  final LinkedHashMap<String, Color> _cache = LinkedHashMap<String, Color>();
  final Map<String, _PendingArtworkColorRequest> _inFlight =
      <String, _PendingArtworkColorRequest>{};

  Future<Color> resolve(String? rawSource) {
    final source = _normalizeSource(rawSource);
    if (source == null || source.isEmpty) {
      return Future<Color>.value(ArtworkProgressColor.fallback);
    }

    final cached = _readCached(source);
    if (cached != null) {
      return Future<Color>.value(cached);
    }

    final pending = _requestFor(source);
    // A Future-only caller has no lifecycle hook with which to release its
    // interest. Keep this request alive until it naturally completes. UI
    // providers use [acquire] instead so their abandoned loads are cancelable.
    pending.retainUntilCompletion = true;
    return pending.future;
  }

  /// Acquires one lifecycle-aware claim on the color for [rawSource].
  ArtworkProgressColorLease acquire(String? rawSource) {
    final source = _normalizeSource(rawSource);
    if (source == null || source.isEmpty) {
      return ArtworkProgressColorLease(
        future: Future<Color>.value(ArtworkProgressColor.fallback),
      );
    }

    final cached = _readCached(source);
    if (cached != null) {
      return ArtworkProgressColorLease(future: Future<Color>.value(cached));
    }

    final pending = _requestFor(source)..leaseCount += 1;
    return ArtworkProgressColorLease._(
      future: pending.future,
      onRelease: () => _release(source, pending),
    );
  }

  _PendingArtworkColorRequest _requestFor(String source) {
    final existing = _inFlight[source];
    if (existing != null) {
      return existing;
    }

    final cancellation = _ArtworkColorCancellation();
    final pending = _PendingArtworkColorRequest(cancellation);
    late final Future<Color> request;
    request = _extractFromSource(source, cancellation)
        .then((color) {
          if (color == null || cancellation.isCancelled) {
            return ArtworkProgressColor.fallback;
          }
          _remember(source, color);
          return color;
        }, onError: (_, _) => ArtworkProgressColor.fallback)
        .whenComplete(() {
          pending.isComplete = true;
          if (identical(_inFlight[source], pending)) {
            _inFlight.remove(source);
          }
        });
    pending.future = request;
    _inFlight[source] = pending;
    return pending;
  }

  void clearCache() => _cache.clear();

  void _release(String source, _PendingArtworkColorRequest pending) {
    if (pending.leaseCount <= 0) {
      return;
    }
    pending.leaseCount -= 1;
    if (pending.leaseCount > 0 ||
        pending.retainUntilCompletion ||
        pending.isComplete) {
      return;
    }

    // Remove the abandoned request before completing its cancellation. A new
    // consumer arriving from a track change must never attach to a request
    // that is already on its way to the fallback value.
    if (identical(_inFlight[source], pending)) {
      _inFlight.remove(source);
    }
    pending.cancellation.cancel();
  }

  void dispose() {
    clearCache();
    final pendingRequests = _inFlight.values.toSet().toList(growable: false);
    _inFlight.clear();
    for (final pending in pendingRequests) {
      pending.cancellation.cancel();
    }
  }

  String? _normalizeSource(String? rawSource) {
    final source = rawSource?.trim();
    return source == null || source.isEmpty ? null : source;
  }

  Color? _readCached(String source) {
    final cached = _cache.remove(source);
    if (cached != null) {
      _cache[source] = cached;
    }
    return cached;
  }

  void _remember(String source, Color color) {
    _cache.remove(source);
    _cache[source] = color;
    while (_cache.length > maximumCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<Color?> _extractFromSource(
    String source,
    _ArtworkColorCancellation cancellation,
  ) async {
    final provider =
        imageProviderForSource?.call(source) ??
        _defaultImageProviderForSource(source);
    if (provider == null) {
      return null;
    }

    final imageInfo = await _loadImage(provider, cancellation);
    if (imageInfo == null) {
      return null;
    }
    try {
      return await _extractArtworkTint(imageInfo);
    } finally {
      imageInfo.dispose();
    }
  }

  ImageProvider<Object>? _defaultImageProviderForSource(String source) {
    if (isNetworkImageSource(source)) {
      return ResizeImage(CachedArtworkImageProvider(source), width: 32);
    }
    final file = imageFileFromSource(source);
    if (file != null && file.existsSync()) {
      return FileImage(file);
    }
    return null;
  }

  Future<ImageInfo?> _loadImage(
    ImageProvider<Object> provider,
    _ArtworkColorCancellation cancellation,
  ) {
    final completer = Completer<ImageInfo?>();
    ImageStream? stream;
    ImageStreamListener? listener;
    Timer? timeout;
    var completed = false;

    void complete(ImageInfo? imageInfo) {
      if (completed) {
        imageInfo?.dispose();
        return;
      }
      completed = true;
      timeout?.cancel();
      cancellation.detach();
      final currentStream = stream;
      final currentListener = listener;
      if (currentStream != null && currentListener != null) {
        currentStream.removeListener(currentListener);
      }
      completer.complete(imageInfo);
    }

    cancellation.attach(() => complete(null));
    if (completed) {
      return completer.future;
    }

    try {
      final resolvedStream = provider.resolve(
        const ImageConfiguration(size: Size.square(32)),
      );
      stream = resolvedStream;
      final resolvedListener = ImageStreamListener(
        (imageInfo, _) => complete(imageInfo),
        onError: (_, _) => complete(null),
      );
      listener = resolvedListener;
      resolvedStream.addListener(resolvedListener);
      if (!completed) {
        timeout = Timer(imageLoadTimeout, () => complete(null));
      }
    } catch (_) {
      complete(null);
    }
    return completer.future;
  }

  Future<Color?> _extractArtworkTint(ImageInfo imageInfo) async {
    const sampleSize = 24;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      imageInfo.image,
      ui.Rect.fromLTWH(
        0,
        0,
        imageInfo.image.width.toDouble(),
        imageInfo.image.height.toDouble(),
      ),
      const ui.Rect.fromLTWH(0, 0, 24, 24),
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    final picture = recorder.endRecording();
    ui.Image? sampledImage;
    try {
      sampledImage = await picture.toImage(sampleSize, sampleSize);
      final data = await sampledImage.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) {
        return null;
      }

      final bytes = data.buffer.asUint8List();
      var hueX = 0.0;
      var hueY = 0.0;
      var saturationSum = 0.0;
      var totalWeight = 0.0;
      for (var index = 0; index + 3 < bytes.length; index += 4) {
        final alpha = bytes[index + 3] / 255;
        if (alpha < 0.2) {
          continue;
        }
        final hsl = HSLColor.fromColor(
          Color.fromARGB(
            bytes[index + 3],
            bytes[index],
            bytes[index + 1],
            bytes[index + 2],
          ),
        );
        final midtoneWeight =
            1 - ((hsl.lightness - 0.5).abs() * 0.55).clamp(0.0, 0.45);
        final weight = alpha * (0.12 + (hsl.saturation * 0.88)) * midtoneWeight;
        final radians = hsl.hue * math.pi / 180;
        hueX += math.cos(radians) * weight;
        hueY += math.sin(radians) * weight;
        saturationSum += hsl.saturation * weight;
        totalWeight += weight;
      }
      if (totalWeight <= 0.001) {
        return null;
      }

      final hue = (math.atan2(hueY, hueX) * 180 / math.pi + 360) % 360;
      final saturation = (saturationSum / totalWeight).clamp(0.28, 0.62);
      return HSLColor.fromAHSL(1, hue, saturation, 0.73).toColor();
    } finally {
      sampledImage?.dispose();
      picture.dispose();
    }
  }
}

final artworkProgressColorServiceProvider =
    Provider<ArtworkProgressColorService>((ref) {
      final service = ArtworkProgressColorService();
      ref.onDispose(service.dispose);
      return service;
    });

final artworkProgressColorProvider = FutureProvider.autoDispose
    .family<Color, String?>((ref, source) {
      final service = ref.watch(artworkProgressColorServiceProvider);
      final lease = service.acquire(source);
      ref.onDispose(lease.release);
      return lease.future;
    });

class _PendingArtworkColorRequest {
  _PendingArtworkColorRequest(this.cancellation);

  final _ArtworkColorCancellation cancellation;
  late final Future<Color> future;
  int leaseCount = 0;
  bool retainUntilCompletion = false;
  bool isComplete = false;
}

class _ArtworkColorCancellation {
  VoidCallback? _callback;
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void attach(VoidCallback callback) {
    if (_isCancelled) {
      callback();
      return;
    }
    _callback = callback;
  }

  void detach() {
    _callback = null;
  }

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    final callback = _callback;
    _callback = null;
    callback?.call();
  }
}
