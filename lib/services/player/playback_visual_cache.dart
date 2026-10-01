import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/utils/image_source.dart';
import '../../core/utils/cached_artwork_image_provider.dart';

/// A session-only cache for the player, bounded to the current song and the
/// two songs played immediately before it. Only complete downloads are used.
class PlaybackVisualCache extends ChangeNotifier {
  PlaybackVisualCache({
    Future<Directory> Function()? directory,
    Future<File?> Function(String)? sharedArtworkLookup,
  }) : _directory = directory ?? _defaultDirectory,
       _sharedArtworkLookup =
           sharedArtworkLookup ?? _defaultSharedArtworkLookup;

  static const maxRetainedTracks = 3;
  static const _maxCoverBytes = 4 * 1024 * 1024;
  static const _maxVideoBytes = 16 * 1024 * 1024;
  static const _failureRetryDelay = Duration(minutes: 2);

  final Future<Directory> Function() _directory;
  final Future<File?> Function(String) _sharedArtworkLookup;
  final LinkedHashMap<String, _VisualEntry> _entries = LinkedHashMap();
  final Set<Timer> _cleanupTimers = {};
  Future<Directory>? _readyDirectory;
  String? _activeKey;
  int _transferSequence = 0;
  int revision = 0;
  bool _disposed = false;

  static Future<Directory> _defaultDirectory() async {
    final root = await getTemporaryDirectory();
    return Directory(
      '${root.path}${Platform.pathSeparator}bstream_visual_cache_v1',
    );
  }

  static Future<File?> _defaultSharedArtworkLookup(String source) async =>
      (await BStreamArtworkCacheManager().getFileFromCache(source))?.file;

  void activate({
    required String trackKey,
    required String? coverSource,
    String? coverFallbackSource,
    required Uri? videoUrl,
  }) {
    if (_disposed) return;
    if (_activeKey != trackKey) {
      final previous = _entries[_activeKey];
      previous?.cancelPending();
      _activeKey = trackKey;
      revision++;
    }

    final entry = _entries.remove(trackKey) ?? _VisualEntry(trackKey);
    _entries[trackKey] = entry;
    while (_entries.length > maxRetainedTracks) {
      final oldest = _entries.keys.first;
      final evicted = _entries.remove(oldest)!;
      evicted.cancelPending();
      // Give an outgoing artwork transition/controller time to release a file.
      _scheduleCleanup(() {
        if (!_entries.containsKey(evicted.key)) _deleteEntry(evicted);
      });
    }

    final source = coverSource?.trim();
    final fallbackSource = coverFallbackSource?.trim();
    if (entry.coverSource != source ||
        entry.coverFallbackSource != fallbackSource) {
      entry.coverTransfer?.cancel();
      entry.coverTransfer = null;
      _retireFile(entry.coverFile, owned: !entry.coverFromSharedCache);
      entry.coverSource = source;
      entry.coverFallbackSource = fallbackSource;
      entry.coverFile = null;
      entry.coverFromSharedCache = false;
      entry.coverFailedAt = null;
      revision++;
    }
    if (entry.videoUrl != videoUrl) {
      entry.videoTransfer?.cancel();
      entry.videoTransfer = null;
      _retireFile(entry.videoFile);
      entry.videoUrl = videoUrl;
      entry.videoFile = null;
      entry.videoFailedAt = null;
      revision++;
    }

    if (source != null &&
        isNetworkImageSource(source) &&
        entry.coverFile == null &&
        entry.coverTransfer == null &&
        _mayRetry(entry.coverFailedAt)) {
      final transfer = _Transfer();
      entry.coverTransfer = transfer;
      unawaited(_loadCover(entry, source, fallbackSource, transfer));
    }
    if (videoUrl != null &&
        (videoUrl.scheme == 'https' || videoUrl.scheme == 'http') &&
        entry.videoFile == null &&
        entry.videoTransfer == null &&
        _mayRetry(entry.videoFailedAt)) {
      final transfer = _Transfer();
      entry.videoTransfer = transfer;
      unawaited(_loadVideo(entry, videoUrl, transfer));
    }
  }

  bool _mayRetry(DateTime? lastFailure) =>
      lastFailure == null ||
      DateTime.now().difference(lastFailure) >= _failureRetryDelay;

  /// A known source with a null file is still downloading. Player artwork
  /// must not start an independent, uncancellable image-cache download.
  bool tracksCover(String source) => _entries.values.any(
    (entry) => entry.coverSource == source && isNetworkImageSource(source),
  );

  String? coverPathFor(String source) {
    for (final entry in _entries.values.toList().reversed) {
      if (entry.coverSource == source) return entry.coverFile?.path;
    }
    return null;
  }

  Uri? videoFileFor(String trackKey, Uri? url) {
    if (url == null) return null;
    final entry = _entries[trackKey];
    if (entry?.videoUrl != url) return null;
    final file = entry?.videoFile;
    return file == null ? null : Uri.file(file.path);
  }

  void deactivate() {
    _entries[_activeKey]?.cancelPending();
    _activeKey = null;
  }

  Future<void> _loadCover(
    _VisualEntry entry,
    String source,
    String? fallbackSource,
    _Transfer transfer,
  ) async {
    File? file;
    var fromSharedCache = false;
    try {
      final candidates = <String>{
        ...artworkDownloadSourceCandidates(source),
        if (fallbackSource != null && isNetworkImageSource(fallbackSource))
          ...artworkDownloadSourceCandidates(fallbackSource),
      };
      // The normal app cache may already contain this cover (e.g. from search
      // or a previous offline session). Reading it must not start a download.
      for (final candidate in candidates) {
        if (transfer.cancelled) break;
        try {
          final cached = await _sharedArtworkLookup(candidate);
          if (cached != null &&
              await cached.exists() &&
              await cached.length() > 0) {
            file = cached;
            fromSharedCache = true;
            break;
          }
        } catch (_) {
          // A unavailable shared-cache database must not hide a live cover.
        }
      }
      for (final candidate in candidates) {
        if (transfer.cancelled || file != null) break;
        final uri = Uri.tryParse(candidate);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          continue;
        }
        file = await _download(
          entry.key,
          uri,
          'cover',
          _maxCoverBytes,
          transfer,
        );
        if (file != null) break;
      }
    } catch (_) {
      // A failed cache lookup or request leaves the existing artwork fallback.
    } finally {
      if (identical(entry.coverTransfer, transfer)) {
        entry.coverTransfer = null;
        if (!transfer.cancelled &&
            file != null &&
            _entries[entry.key] == entry &&
            entry.coverSource == source) {
          entry.coverFile = file;
          entry.coverFromSharedCache = fromSharedCache;
          assert(() {
            debugPrint(
              'BStream visual cover ${entry.key}: ${file!.lengthSync()} bytes',
            );
            return true;
          }());
          _changed();
        } else if (!transfer.cancelled && file == null) {
          entry.coverFailedAt = DateTime.now();
        }
      }
    }
  }

  Future<void> _loadVideo(
    _VisualEntry entry,
    Uri url,
    _Transfer transfer,
  ) async {
    File? file;
    try {
      file = await _download(entry.key, url, 'video', _maxVideoBytes, transfer);
    } catch (_) {
      // The cover remains visible when a video request fails.
    } finally {
      if (identical(entry.videoTransfer, transfer)) {
        entry.videoTransfer = null;
        if (!transfer.cancelled &&
            file != null &&
            _entries[entry.key] == entry &&
            entry.videoUrl == url) {
          entry.videoFile = file;
          assert(() {
            debugPrint(
              'BStream visual video ${entry.key}: ${file!.lengthSync()} bytes',
            );
            return true;
          }());
          _changed();
        } else if (!transfer.cancelled && file == null) {
          entry.videoFailedAt = DateTime.now();
        }
      }
    }
  }

  Future<File?> _download(
    String trackKey,
    Uri url,
    String kind,
    int maxBytes,
    _Transfer transfer,
  ) async {
    final folder = await (_readyDirectory ??= _prepareDirectory());
    if (transfer.cancelled) return null;
    final hash = sha256.convert(utf8.encode('$trackKey|$kind|$url')).toString();
    final target = File(
      '${folder.path}${Platform.pathSeparator}$hash.${kind == 'video' ? 'mp4' : 'img'}',
    );
    if (await target.exists() && await target.length() > 0) return target;
    if (await target.exists()) {
      try {
        await target.delete();
      } catch (_) {
        return null;
      }
    }
    final partial = File('${target.path}.part-${++_transferSequence}');
    HttpClient? client;
    RandomAccessFile? output;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      transfer.client = client;
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 10));
      transfer.request = request;
      if (transfer.cancelled) return null;
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final mime = response.headers.contentType?.mimeType;
      if (response.statusCode != HttpStatus.ok ||
          (response.contentLength >= 0 && response.contentLength > maxBytes) ||
          (mime != null &&
              mime != 'application/octet-stream' &&
              !(kind == 'video'
                  ? mime.startsWith('video/') || mime == 'application/mp4'
                  : mime.startsWith('image/')))) {
        return null;
      }
      output = await partial.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        if (transfer.cancelled) return null;
        received += chunk.length;
        if (received > maxBytes) return null;
        await output.writeFrom(chunk);
      }
      await output.close();
      output = null;
      if (transfer.cancelled || received == 0) return null;
      return await partial.rename(target.path);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
      transfer.client = null;
      transfer.request = null;
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
      }
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
    }
  }

  Future<Directory> _prepareDirectory() async {
    final folder = await _directory();
    await folder.create(recursive: true);
    // This cache is intentionally session-only. Never touch the parent temp
    // directory or another cache owned by the app.
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    return folder;
  }

  Future<void> _deleteEntry(_VisualEntry entry) async {
    for (final file in [
      if (!entry.coverFromSharedCache) entry.coverFile,
      entry.videoFile,
    ]) {
      if (file == null) continue;
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  void _retireFile(File? file, {bool owned = true}) {
    if (file == null || !owned) return;
    _scheduleCleanup(() async {
      if (_entries.values.any(
        (entry) =>
            entry.coverFile?.path == file.path ||
            entry.videoFile?.path == file.path,
      )) {
        return;
      }
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    });
  }

  void _scheduleCleanup(FutureOr<void> Function() action) {
    late final Timer timer;
    timer = Timer(const Duration(seconds: 2), () {
      _cleanupTimers.remove(timer);
      unawaited(Future<void>.sync(action));
    });
    _cleanupTimers.add(timer);
  }

  void _changed() {
    if (_disposed) return;
    revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _cleanupTimers) {
      timer.cancel();
    }
    _cleanupTimers.clear();
    for (final entry in _entries.values) {
      entry.cancelPending();
    }
    super.dispose();
  }
}

class _VisualEntry {
  _VisualEntry(this.key);
  final String key;
  String? coverSource;
  String? coverFallbackSource;
  File? coverFile;
  bool coverFromSharedCache = false;
  DateTime? coverFailedAt;
  Uri? videoUrl;
  File? videoFile;
  DateTime? videoFailedAt;
  _Transfer? coverTransfer;
  _Transfer? videoTransfer;

  void cancelPending() {
    coverTransfer?.cancel();
    coverTransfer = null;
    videoTransfer?.cancel();
    videoTransfer = null;
  }
}

class _Transfer {
  bool cancelled = false;
  HttpClient? client;
  HttpClientRequest? request;

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    try {
      request?.abort();
    } catch (_) {}
    client?.close(force: true);
  }
}
