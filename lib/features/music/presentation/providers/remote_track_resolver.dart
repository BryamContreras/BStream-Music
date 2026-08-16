part of 'music_providers.dart';

TrackInfo _mergeTrackInfo(TrackInfo base, TrackInfo resolved) {
  final hasResolvedTransport =
      resolved.streamUrl != null && resolved.streamUrl!.trim().isNotEmpty;
  final preserveMusicMetadata =
      base.metadataSource == TrackMetadataSource.youtubeMusic;
  final baseArtists = _meaningfulArtists(base.artists);
  final resolvedArtists = _meaningfulArtists(resolved.artists);
  final artists = preserveMusicMetadata
      ? (baseArtists.isNotEmpty ? baseArtists : resolvedArtists)
      : (resolvedArtists.isNotEmpty ? resolvedArtists : baseArtists);
  return TrackInfo(
    id: preserveMusicMetadata
        ? _preferredIdentifier(base.id, resolved.id)
        : (resolved.id.isNotEmpty ? resolved.id : base.id),
    title: preserveMusicMetadata
        ? _preferredText(base.title, resolved.title, 'Sin título')
        : _preferredText(resolved.title, base.title, 'Sin título'),
    artist: preserveMusicMetadata
        ? (artists.isNotEmpty
              ? artists.join(', ')
              : _preferredText(base.artist, resolved.artist, 'Desconocido'))
        : _preferredText(resolved.artist, base.artist, 'Desconocido'),
    url: preserveMusicMetadata
        ? _preferredIdentifier(base.url, resolved.url)
        : (resolved.url.isNotEmpty ? resolved.url : base.url),
    thumbnailUrl: preserveMusicMetadata
        ? _preferredOptionalText(base.thumbnailUrl, resolved.thumbnailUrl)
        : _preferredOptionalText(resolved.thumbnailUrl, base.thumbnailUrl),
    catalogThumbnailUrl: preserveMusicMetadata
        ? _preferredOptionalText(
            base.catalogThumbnailUrl,
            resolved.catalogThumbnailUrl,
          )
        : _preferredOptionalText(
            resolved.catalogThumbnailUrl,
            base.catalogThumbnailUrl,
          ),
    duration: preserveMusicMetadata
        ? base.duration ?? resolved.duration
        : resolved.duration ?? base.duration,
    streamUrl: resolved.streamUrl ?? base.streamUrl,
    streamExtension: hasResolvedTransport
        ? resolved.streamExtension
        : resolved.streamExtension ?? base.streamExtension,
    streamMimeType: hasResolvedTransport
        ? resolved.streamMimeType
        : resolved.streamMimeType ?? base.streamMimeType,
    streamSource: hasResolvedTransport
        ? resolved.streamSource
        : base.streamSource,
    streamFormatId: hasResolvedTransport
        ? resolved.streamFormatId
        : base.streamFormatId,
    streamCodec: hasResolvedTransport ? resolved.streamCodec : base.streamCodec,
    extractor: resolved.extractor ?? base.extractor,
    album: preserveMusicMetadata
        ? _preferredOptionalText(base.album, resolved.album)
        : _preferredOptionalText(resolved.album, base.album),
    viewCount: resolved.viewCount ?? base.viewCount,
    httpHeaders: hasResolvedTransport
        ? resolved.httpHeaders
        : resolved.httpHeaders ?? base.httpHeaders,
    artists: artists,
    metadataSource: preserveMusicMetadata
        ? base.metadataSource
        : resolved.metadataSource,
  );
}

String _preferredIdentifier(String preferred, String fallback) {
  return preferred.trim().isNotEmpty ? preferred : fallback;
}

String? _preferredOptionalText(String? preferred, String? fallback) {
  final normalized = preferred?.trim();
  if (normalized != null && normalized.isNotEmpty) {
    return preferred;
  }
  final fallbackNormalized = fallback?.trim();
  return fallbackNormalized == null || fallbackNormalized.isEmpty
      ? null
      : fallback;
}

List<String> _meaningfulArtists(List<String> artists) {
  final result = <String>[];
  for (final artist in artists) {
    final normalized = artist.trim();
    if (normalized.isEmpty || _isPlaceholderText(normalized)) {
      continue;
    }
    if (!result.contains(normalized)) {
      result.add(normalized);
    }
  }
  return List.unmodifiable(result);
}

String _preferredText(String preferred, String fallback, String placeholder) {
  final normalized = preferred.trim();
  final fallbackNormalized = fallback.trim();
  if (normalized.isEmpty ||
      normalized.toLowerCase() == placeholder.toLowerCase() ||
      _isPlaceholderText(normalized)) {
    if (fallbackNormalized.isEmpty) {
      return preferred;
    }
    return fallback;
  }
  return preferred;
}

bool _isPlaceholderText(String value) {
  return const {
    'desconocido',
    'unknown',
    'unknown artist',
    'sin artista',
    'sin titulo',
    'sin título',
    'untitled',
  }.contains(value.trim().toLowerCase());
}

final remoteTrackResolverProvider = Provider<RemoteTrackResolver>((ref) {
  final resolver = RemoteTrackResolver(ref);
  ref.onDispose(resolver.dispose);
  return resolver;
});

class RemoteTrackResolver {
  RemoteTrackResolver(this._ref, {bool? isAndroid})
    : _isAndroid = isAndroid ?? AppPlatform.isAndroid;

  static const _ttl = Duration(minutes: 20);
  static const _prefsKey = 'remote_track_resolution_cache_v4';
  static const _legacyPrefsKeys = [
    'remote_track_resolution_cache_v2',
    'remote_track_resolution_cache_v3',
  ];
  static const _maxPersistentEntries = 24;
  static const _maxMemoryEntries = 32;

  final Ref _ref;
  final bool _isAndroid;
  final _entries = <String, _TrackResolutionEntry>{};
  bool _loadedPersistentCache = false;

  Future<TrackInfo> resolve(
    TrackInfo track, {
    bool forceRefresh = false,
    bool allowStaleStreamFallback = true,
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
    AudioResolverFailureCallback? onResolverFailure,
    AudioResolverContinuationCallback? shouldContinue,
  }) async {
    final key = _cacheKey(track);
    if (key.isEmpty) {
      return track;
    }

    await _loadPersistentCache();
    _trimMemoryEntries();

    final cached = _entries[key];
    if (!forceRefresh &&
        mode == AudioResolutionMode.primaryThenFallback &&
        cached != null &&
        !cached.isExpired) {
      return cached.future.then((resolved) => _mergeTrackInfo(track, resolved));
    }

    final future = _resolveAndCache(
      track,
      key,
      forceRefresh: forceRefresh,
      allowStaleStreamFallback: allowStaleStreamFallback,
      mode: mode,
      onResolverFailure: onResolverFailure,
      shouldContinue: shouldContinue,
    );

    _entries[key] = _TrackResolutionEntry(future);
    _trimMemoryEntries(preserveKey: key);
    return future;
  }

  void dispose() {
    _entries.clear();
  }

  String _cacheKey(TrackInfo track) {
    if (track.url.trim().isNotEmpty) {
      return track.url;
    }
    return track.id;
  }

  Future<TrackInfo> _resolveAndCache(
    TrackInfo track,
    String key, {
    required bool forceRefresh,
    required bool allowStaleStreamFallback,
    required AudioResolutionMode mode,
    required AudioResolverFailureCallback? onResolverFailure,
    required AudioResolverContinuationCallback? shouldContinue,
  }) async {
    try {
      final resolver = _ref.read(audioStreamResolverProvider);
      final resolved = resolver is FallbackAwareAudioStreamResolver
          ? await (resolver as FallbackAwareAudioStreamResolver)
                .resolveWithMode(
                  track,
                  mode: mode,
                  onResolverFailure: onResolverFailure,
                  shouldContinue: shouldContinue,
                )
          : await resolver.resolve(track);
      if (shouldContinue != null && !shouldContinue()) {
        throw const AudioStreamResolverException(
          'Audio stream resolution was superseded.',
        );
      }
      final merged = _mergeTrackInfo(track, _trackFromResolution(resolved));
      if (_hasPlayableStream(merged)) {
        unawaited(_persistResolvedEntry(key, merged));
      }
      return merged;
    } catch (_) {
      _entries.remove(key);
      if (forceRefresh) {
        unawaited(_removePersistentEntry(key));
      }
      if (allowStaleStreamFallback && _hasPlayableStream(track)) {
        return track;
      }
      rethrow;
    }
  }

  TrackInfo _trackFromResolution(AudioStreamResolution resolution) {
    return TrackInfo(
      id: '',
      title: '',
      artist: '',
      url: '',
      streamUrl: resolution.streamUrl,
      streamExtension: resolution.streamExtension,
      streamMimeType: resolution.streamMimeType,
      streamSource: resolution.source.name,
      streamFormatId: resolution.formatId,
      streamCodec: resolution.codec,
      httpHeaders: resolution.httpHeaders,
    );
  }

  Future<void> _loadPersistentCache() async {
    if (_loadedPersistentCache) {
      return;
    }
    _loadedPersistentCache = true;

    final prefs = await SharedPreferences.getInstance();
    for (final legacyKey in _legacyPrefsKeys) {
      await prefs.remove(legacyKey);
    }

    // Stream URLs and their headers are signed and short-lived. They must not
    // survive an Android process restart or be reused after a download.
    if (_isAndroid) {
      await prefs.remove(_prefsKey);
      return;
    }

    final cache = _readPersistentCache(prefs.getString(_prefsKey));
    var removedExpired = false;

    final now = DateTime.now();
    for (final entry in cache.entries) {
      final value = entry.value;
      if (_isPersistentEntryExpired(value, now)) {
        removedExpired = true;
        continue;
      }

      final track = _trackFromPersistentEntry(value);
      if (track == null || !_hasPlayableStream(track)) {
        removedExpired = true;
        continue;
      }

      _entries[entry.key] = _TrackResolutionEntry(
        Future.value(track),
        createdAt: _persistentEntryCreatedAt(value),
      );
    }

    if (removedExpired) {
      cache.removeWhere((_, value) => _isPersistentEntryExpired(value, now));
      await prefs.setString(_prefsKey, jsonEncode(cache));
    }
  }

  Future<void> _persistResolvedEntry(String key, TrackInfo track) async {
    // Managed playback files live in an OS cache directory. Keep them in the
    // in-memory resolver cache for this session, but never persist paths that
    // the OS may remove between launches.
    final streamUri = Uri.tryParse(track.streamUrl ?? '');
    if (_isAndroid || !_hasPlayableStream(track)) {
      return;
    }
    if (streamUri?.scheme == 'file') {
      await _removePersistentEntry(key);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final cache = _readPersistentCache(prefs.getString(_prefsKey));
    final now = DateTime.now();
    cache.removeWhere((_, value) => _isPersistentEntryExpired(value, now));
    cache[key] = {
      'createdAt': now.millisecondsSinceEpoch,
      'track': _trackInfoModel(track).toJson(),
    };
    _trimPersistentCache(cache);
    await prefs.setString(_prefsKey, jsonEncode(cache));
  }

  Future<void> _removePersistentEntry(String key) async {
    if (_isAndroid) {
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final cache = _readPersistentCache(prefs.getString(_prefsKey));
      if (cache.remove(key) == null) {
        return;
      }
      await prefs.setString(_prefsKey, jsonEncode(cache));
    } catch (_) {
      // A cache cleanup failure must not hide the original playback error.
    }
  }

  Map<String, dynamic> _readPersistentCache(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return {};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return {};
      }
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (_) {
      return {};
    }
  }

  void _trimPersistentCache(Map<String, dynamic> cache) {
    if (cache.length <= _maxPersistentEntries) {
      return;
    }

    final entries = cache.entries.toList()
      ..sort((left, right) {
        final leftCreated =
            _persistentEntryCreatedAt(left.value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final rightCreated =
            _persistentEntryCreatedAt(right.value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return leftCreated.compareTo(rightCreated);
      });

    for (final entry in entries.take(cache.length - _maxPersistentEntries)) {
      cache.remove(entry.key);
    }
  }

  void _trimMemoryEntries({String? preserveKey}) {
    _entries.removeWhere((key, entry) => key != preserveKey && entry.isExpired);
    if (_entries.length <= _maxMemoryEntries) {
      return;
    }

    final oldest =
        _entries.entries
            .where((entry) => entry.key != preserveKey)
            .toList(growable: false)
          ..sort(
            (left, right) =>
                left.value.createdAt.compareTo(right.value.createdAt),
          );
    final removeCount = _entries.length - _maxMemoryEntries;
    for (final entry in oldest.take(removeCount)) {
      _entries.remove(entry.key);
    }
  }

  TrackInfo? _trackFromPersistentEntry(Object? value) {
    if (value is! Map) {
      return null;
    }
    final track = value['track'];
    if (track is! Map) {
      return null;
    }

    try {
      return TrackInfoModel.fromJson(
        track.map((key, data) => MapEntry(key.toString(), data)),
      );
    } catch (_) {
      return null;
    }
  }

  DateTime? _persistentEntryCreatedAt(Object? value) {
    if (value is! Map) {
      return null;
    }
    final raw = value['createdAt'];
    final milliseconds = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (milliseconds == null || milliseconds <= 0) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  bool _isPersistentEntryExpired(Object? value, DateTime now) {
    final createdAt = _persistentEntryCreatedAt(value);
    if (createdAt == null) {
      return true;
    }
    return now.difference(createdAt) > _ttl;
  }

  bool _hasPlayableStream(TrackInfo track) {
    return track.streamUrl != null && track.streamUrl!.trim().isNotEmpty;
  }

  TrackInfoModel _trackInfoModel(TrackInfo track) {
    return TrackInfoModel(
      id: track.id,
      title: track.title,
      artist: track.artist,
      url: track.url,
      thumbnailUrl: track.thumbnailUrl,
      catalogThumbnailUrl: track.catalogThumbnailUrl,
      duration: track.duration,
      streamUrl: track.streamUrl,
      streamExtension: track.streamExtension,
      streamMimeType: track.streamMimeType,
      streamSource: track.streamSource,
      streamFormatId: track.streamFormatId,
      streamCodec: track.streamCodec,
      extractor: track.extractor,
      album: track.album,
      viewCount: track.viewCount,
      httpHeaders: track.httpHeaders,
      artists: track.artists,
      metadataSource: track.metadataSource,
    );
  }
}

class _TrackResolutionEntry {
  _TrackResolutionEntry(this.future, {DateTime? createdAt})
    : createdAt = createdAt ?? DateTime.now();

  final Future<TrackInfo> future;
  final DateTime createdAt;

  bool get isExpired =>
      DateTime.now().difference(createdAt) > RemoteTrackResolver._ttl;
}
