import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as image;

import '../../../../core/utils/cached_artwork_image_provider.dart';
import '../../../../core/utils/image_source.dart';

const liveOverlayArtworkSize = 96;
const liveOverlayArtworkByteCount =
    liveOverlayArtworkSize * liveOverlayArtworkSize * 4;

typedef LiveOverlayArtworkLoader = Future<String?> Function(String source);

/// Resolves artwork through BStream's persistent cache and creates a compact
/// PNG data URI that a localhost browser source can render without receiving a
/// private file path or depending on the remote thumbnail staying online.
class LiveOverlayArtworkService {
  LiveOverlayArtworkService({
    this.timeout = const Duration(seconds: 8),
    this.maximumCachedItems = 64,
  });

  static const _maximumEncodedBytes = 20 * 1024 * 1024;
  static const _maximumDecodeDimension = 768;

  BStreamArtworkCacheManager? _cacheManager;
  final Duration timeout;
  final int maximumCachedItems;
  final LinkedHashMap<String, String?> _memoryCache =
      LinkedHashMap<String, String?>();
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  Future<String?> load(String source) {
    final normalized = source.trim();
    if (normalized.isEmpty) return Future<String?>.value();

    if (_memoryCache.containsKey(normalized)) {
      final cached = _memoryCache.remove(normalized);
      _memoryCache[normalized] = cached;
      return Future<String?>.value(cached);
    }

    return _inFlight.putIfAbsent(normalized, () async {
      final result = await _loadUncached(normalized);
      _memoryCache[normalized] = result;
      while (_memoryCache.length > maximumCachedItems) {
        _memoryCache.remove(_memoryCache.keys.first);
      }
      _inFlight.remove(normalized);
      return result;
    });
  }

  Future<String?> _loadUncached(String source) async {
    for (final candidate in _sourceCandidates(source)) {
      try {
        final file = isNetworkImageSource(candidate)
            ? await (_cacheManager ??= BStreamArtworkCacheManager())
                  .getSingleFile(candidate)
                  .timeout(timeout)
            : imageFileFromSource(candidate);
        if (file == null || !await file.exists()) continue;
        final length = await file.length();
        if (length <= 0 || length > _maximumEncodedBytes) continue;
        final encoded = await file.readAsBytes().timeout(timeout);
        final rgba = await _centerCropRgba(encoded).timeout(timeout);
        if (rgba == null) continue;
        final square = image.Image.fromBytes(
          width: liveOverlayArtworkSize,
          height: liveOverlayArtworkSize,
          bytes: rgba.buffer,
          bytesOffset: rgba.offsetInBytes,
          numChannels: 4,
          order: image.ChannelOrder.rgba,
        );
        final png = image.encodePng(square, level: 6);
        return 'data:image/png;base64,${base64Encode(png)}';
      } catch (_) {
        // A cover is optional. Continue with another known rendition and let
        // the overlay use its accent-colored fallback if none can be decoded.
      }
    }
    return null;
  }

  List<String> _sourceCandidates(String source) {
    if (!isNetworkImageSource(source)) return <String>[source];
    if (youtubeVideoIdFromThumbnailSource(source) != null) {
      return youtubeThumbnailPreviewCandidates(source);
    }
    final sized = sizedGoogleArtworkSource(source, liveOverlayArtworkSize);
    return <String>{?sized, source}.toList(growable: false);
  }

  Future<Uint8List?> _centerCropRgba(Uint8List encoded) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 || descriptor.height <= 0) return null;

      final shorter = math.min(descriptor.width, descriptor.height);
      final scale = liveOverlayArtworkSize / shorter;
      var targetWidth = math.max(
        liveOverlayArtworkSize,
        (descriptor.width * scale).round(),
      );
      var targetHeight = math.max(
        liveOverlayArtworkSize,
        (descriptor.height * scale).round(),
      );
      targetWidth = math.min(targetWidth, _maximumDecodeDimension);
      targetHeight = math.min(targetHeight, _maximumDecodeDimension);

      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      decoded = (await codec.getNextFrame()).image;
      final byteData = await decoded.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (byteData == null ||
          decoded.width < liveOverlayArtworkSize ||
          decoded.height < liveOverlayArtworkSize) {
        return null;
      }

      final sourcePixels = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final output = Uint8List(liveOverlayArtworkByteCount);
      final sourceLeft = (decoded.width - liveOverlayArtworkSize) ~/ 2;
      final sourceTop = (decoded.height - liveOverlayArtworkSize) ~/ 2;
      const outputStride = liveOverlayArtworkSize * 4;
      final sourceStride = decoded.width * 4;
      for (var row = 0; row < liveOverlayArtworkSize; row++) {
        final sourceOffset = (sourceTop + row) * sourceStride + sourceLeft * 4;
        final outputOffset = row * outputStride;
        output.setRange(
          outputOffset,
          outputOffset + outputStride,
          sourcePixels,
          sourceOffset,
        );
      }
      return output;
    } catch (_) {
      return null;
    } finally {
      decoded?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
