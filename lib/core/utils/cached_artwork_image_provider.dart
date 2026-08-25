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
    try {
      final file = await key.cacheManager.getSingleFile(key.url);
      if (await file.length() == 0) {
        await key.cacheManager.removeFile(key.url);
        throw StateError('Cached artwork is empty: ${key.url}');
      }
      return await decode(await ui.ImmutableBuffer.fromFilePath(file.path));
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
