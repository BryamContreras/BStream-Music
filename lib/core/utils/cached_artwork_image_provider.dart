import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Persistent cache dedicated to artwork shown throughout BStream.
///
/// Flutter's [ImageCache] only retains decoded pixels in memory. This cache
/// keeps the compressed response on disk as well, so an evicted album cover or
/// artist portrait does not need another network round trip while scrolling.
class BStreamArtworkCacheManager extends CacheManager {
  factory BStreamArtworkCacheManager() => _instance;

  BStreamArtworkCacheManager._()
    : super(
        Config(
          _cacheKey,
          stalePeriod: const Duration(days: 60),
          maxNrOfCacheObjects: 800,
        ),
      );

  static const _cacheKey = 'bstreamArtworkCacheV1';
  static final BStreamArtworkCacheManager _instance =
      BStreamArtworkCacheManager._();
}

/// An [ImageProvider] backed by BStream's persistent artwork cache.
@immutable
class CachedArtworkImageProvider
    extends ImageProvider<CachedArtworkImageProvider> {
  CachedArtworkImageProvider(
    this.url, {
    this.scale = 1,
    BaseCacheManager? cacheManager,
  }) : cacheManager = cacheManager ?? BStreamArtworkCacheManager();

  final String url;
  final double scale;
  final BaseCacheManager cacheManager;

  // Only the known YouTube upgrade path needs this metadata. The cache key
  // matches the decoded-image provider, so another widget can reuse the proof
  // along with Flutter's decoded image without inspecting pixels on the GPU.
  static final _verifiedOpaque = <CachedArtworkImageProvider>{};
  static const _maximumOpacityEntries = 128;

  bool get hasVerifiedOpaqueJpeg => _verifiedOpaque.contains(this);

  bool get _isYoutubeUpgrade {
    final uri = Uri.tryParse(url);
    return uri?.host == 'i.ytimg.com' &&
        uri!.pathSegments.length == 3 &&
        uri.pathSegments.first == 'vi' &&
        uri.pathSegments.last == 'hq720.jpg';
  }

  @override
  Future<CachedArtworkImageProvider> obtainKey(ImageConfiguration _) =>
      SynchronousFuture<CachedArtworkImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    CachedArtworkImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('URL', url),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    CachedArtworkImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    _verifiedOpaque.remove(key);
    try {
      final file = await key.cacheManager.getSingleFile(key.url);
      if (await file.length() == 0) {
        await key.cacheManager.removeFile(key.url);
        throw StateError('Cached artwork is empty: ${key.url}');
      }
      // A JPEG signature proves that a successfully decoded rendition is
      // opaque. Do not make a filename or MIME type assumption, and avoid a
      // GPU readback just to check alpha. This reads only three cached bytes.
      var opaqueJpeg = false;
      if (key._isYoutubeUpgrade) {
        try {
          final header = await file.openRead(0, 3).first;
          opaqueJpeg =
              header.length == 3 &&
              header[0] == 0xff &&
              header[1] == 0xd8 &&
              header[2] == 0xff;
        } catch (_) {
          // Keep the preview if the optional metadata cannot be established.
        }
      }
      final codec = await decode(
        await ui.ImmutableBuffer.fromFilePath(file.path),
      );
      if (opaqueJpeg) {
        _verifiedOpaque.add(key);
        if (_verifiedOpaque.length > _maximumOpacityEntries) {
          _verifiedOpaque.remove(_verifiedOpaque.first);
        }
      }
      return codec;
    } catch (_) {
      try {
        await key.cacheManager.removeFile(key.url);
      } catch (_) {
        // The original transfer/decoding error remains authoritative.
      }
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedArtworkImageProvider &&
          other.url == url &&
          other.scale == scale &&
          identical(other.cacheManager, cacheManager);

  @override
  int get hashCode => Object.hash(url, scale, identityHashCode(cacheManager));
}
