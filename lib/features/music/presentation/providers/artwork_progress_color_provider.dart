import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/image_source.dart';

/// Shared colors used by artwork-tinted playback progress indicators.
abstract final class ArtworkProgressColor {
  static const fallback = Color(0xFF91CDA7);
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
  }) : assert(maximumCacheEntries > 0),
       assert(imageLoadTimeout > Duration.zero);

  final int maximumCacheEntries;
  final Duration imageLoadTimeout;
  final LinkedHashMap<String, Color> _cache = LinkedHashMap<String, Color>();
  final Map<String, Future<Color>> _inFlight = <String, Future<Color>>{};

  Future<Color> resolve(String? rawSource) {
    final source = rawSource?.trim();
    if (source == null || source.isEmpty) {
      return Future<Color>.value(ArtworkProgressColor.fallback);
    }

    final cached = _cache.remove(source);
    if (cached != null) {
      _cache[source] = cached;
      return Future<Color>.value(cached);
    }

    final pending = _inFlight[source];
    if (pending != null) {
      return pending;
    }

    late final Future<Color> request;
    request = _extractFromSource(source)
        .then((color) {
          if (color == null) {
            return ArtworkProgressColor.fallback;
          }
          _remember(source, color);
          return color;
        }, onError: (_, _) => ArtworkProgressColor.fallback)
        .whenComplete(() {
          if (identical(_inFlight[source], request)) {
            _inFlight.remove(source);
          }
        });
    _inFlight[source] = request;
    return request;
  }

  void clearCache() => _cache.clear();

  void _remember(String source, Color color) {
    _cache.remove(source);
    _cache[source] = color;
    while (_cache.length > maximumCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<Color?> _extractFromSource(String source) async {
    ImageProvider<Object>? provider;
    if (isNetworkImageSource(source)) {
      provider = NetworkImage(source);
    } else {
      final file = imageFileFromSource(source);
      if (file != null && file.existsSync()) {
        provider = FileImage(file);
      }
    }
    if (provider == null) {
      return null;
    }

    final imageInfo = await _loadImage(provider);
    if (imageInfo == null) {
      return null;
    }
    try {
      return await _extractArtworkTint(imageInfo);
    } finally {
      imageInfo.dispose();
    }
  }

  Future<ImageInfo?> _loadImage(ImageProvider<Object> provider) {
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
      final currentStream = stream;
      final currentListener = listener;
      if (currentStream != null && currentListener != null) {
        currentStream.removeListener(currentListener);
      }
      completer.complete(imageInfo);
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
      ref.onDispose(service.clearCache);
      return service;
    });

final artworkProgressColorProvider = FutureProvider.autoDispose
    .family<Color, String?>((ref, source) {
      return ref.watch(artworkProgressColorServiceProvider).resolve(source);
    });
