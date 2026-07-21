part of 'music_providers.dart';

TrackInfo _mergeTrackInfo(TrackInfo base, TrackInfo resolved) {
  return TrackInfo(
    id: resolved.id.isNotEmpty ? resolved.id : base.id,
    title: _preferredText(resolved.title, base.title, 'Sin titulo'),
    artist: _preferredText(resolved.artist, base.artist, 'Desconocido'),
    url: resolved.url.isNotEmpty ? resolved.url : base.url,
    thumbnailUrl: resolved.thumbnailUrl ?? base.thumbnailUrl,
    duration: resolved.duration ?? base.duration,
    streamUrl: resolved.streamUrl ?? base.streamUrl,
    extractor: resolved.extractor ?? base.extractor,
    album: resolved.album ?? base.album,
    viewCount: resolved.viewCount ?? base.viewCount,
    httpHeaders: resolved.httpHeaders ?? base.httpHeaders,
  );
}

String _preferredText(String preferred, String fallback, String placeholder) {
  final normalized = preferred.trim();
  if (normalized.isEmpty || normalized == placeholder) {
    return fallback;
  }
  return preferred;
}

final remoteTrackResolverProvider = Provider<RemoteTrackResolver>((ref) {
  final resolver = RemoteTrackResolver(ref);
  ref.onDispose(resolver.dispose);
  return resolver;
});

class RemoteTrackResolver {
  RemoteTrackResolver(this._ref);

  static const _ttl = Duration(minutes: 20);
  static const _prefsKey = 'remote_track_resolution_cache_v2';
  static const _maxPersistentEntries = 24;

  final Ref _ref;
  final _entries = <String, _TrackResolutionEntry>{};
  bool _loadedPersistentCache = false;

  Future<TrackInfo> resolve(
    TrackInfo track, {
    bool forceRefresh = false,
  }) async {
    final key = _cacheKey(track);
    if (key.isEmpty) {
      return track;
    }

    await _loadPersistentCache();

    final cached = _entries[key];
    if (!forceRefresh && cached != null && !cached.isExpired) {
      return cached.future.then((resolved) => _mergeTrackInfo(track, resolved));
    }

    final future = _resolveAndCache(track, key);

    _entries[key] = _TrackResolutionEntry(future);
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

  Future<TrackInfo> _resolveAndCache(TrackInfo track, String key) async {
    try {
      final resolver = AppPlatform.isAndroid
          ? _ref.read(getPlaybackInfoProvider).call
          : _ref.read(getTrackInfoProvider).call;
      final resolved = _mergeTrackInfo(track, await resolver(track.url));
      if (_hasPlayableStream(resolved)) {
        unawaited(_persistResolvedEntry(key, resolved));
      }
      return resolved;
    } catch (_) {
      _entries.remove(key);
      return track;
    }
  }

  Future<void> _loadPersistentCache() async {
    if (_loadedPersistentCache) {
      return;
    }
    _loadedPersistentCache = true;

    final prefs = await SharedPreferences.getInstance();
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
    if (!_hasPlayableStream(track)) {
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
      duration: track.duration,
      streamUrl: track.streamUrl,
      extractor: track.extractor,
      album: track.album,
      viewCount: track.viewCount,
      httpHeaders: track.httpHeaders,
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
