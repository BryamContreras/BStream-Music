import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/utils/cached_artwork_image_provider.dart';
import '../../core/utils/image_source.dart';

/// A small, event-driven snapshot for the native home-screen widgets.
/// Position is deliberately omitted: publishing every playback tick would
/// wake the launcher and WidgetKit unnecessarily.
class HomeScreenWidgetSync {
  HomeScreenWidgetSync({
    MethodChannel? channel,
    this.onAction,
    this.supportsQueue = false,
  }) : _channel = channel ?? const MethodChannel('bstream_music/home_widget') {
    _channel.setMethodCallHandler(_handleCall);
    unawaited(_registerAndConsumePendingAction());
  }

  final MethodChannel _channel;
  static final _queueWhitespace = RegExp(r'\s+');
  static const _queueArtworkRetryDelay = Duration(seconds: 20);
  final Future<void> Function(String action)? onAction;

  /// Only Android currently exposes a queue in its native home-screen widget.
  /// Other widgets need the current song and must not prefetch queue artwork.
  final bool supportsQueue;
  int _generation = 0;
  int? _artworkRequestGeneration;
  String? _lastIdentity;
  String? _currentArtworkIdentity;
  String? _lastArtworkIdentity;
  String? _currentQueueJson;
  int _queueRevision = 0;
  DateTime? _queueArtworkRetryAt;
  Map<String, Object?> _currentWidgetData = const {};
  final Map<String, ({String? path, DateTime checkedAt})>
  _queueArtworkPathCache = {};

  Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method == 'widgetAction' && call.arguments is String) {
      await onAction?.call(call.arguments as String);
    }
    return null;
  }

  Future<void> _consumePendingAction() async {
    try {
      final action = await _channel.invokeMethod<String>(
        'consumePendingAction',
      );
      if (action != null) await onAction?.call(action);
    } on MissingPluginException {
      // Widgets are not present on desktop builds.
    } catch (error) {
      debugPrint('Home widget pending action failed: $error');
    }
  }

  Future<void> _registerAndConsumePendingAction() async {
    try {
      await _channel.invokeMethod<void>('registerActionHandler');
    } on MissingPluginException {
      // Desktop builds do not include native home-screen widget support.
    } catch (error) {
      debugPrint('Home widget action registration failed: $error');
    }
    await _consumePendingAction();
  }

  void publish({
    required String? trackId,
    required String? title,
    required String? artist,
    required String? artworkUrl,
    required bool isPlaying,
    bool isLoading = false,
    String? loadingLabel,
    required bool isFavorite,
    required String repeatMode,
    required int accentColor,
    required String languageCode,
    Iterable<Map<String, String>> queue = const [],
    int currentQueueIndex = -1,
  }) {
    final queueJson = supportsQueue
        ? _encodeQueue(queue, currentQueueIndex)
        : '[]';
    final identity =
        '$trackId\u0000$title\u0000$artist\u0000$artworkUrl\u0000'
        '$isPlaying\u0000$isLoading\u0000$loadingLabel\u0000$isFavorite\u0000$repeatMode\u0000'
        '$accentColor\u0000$languageCode\u0000$queueJson';
    if (identity == _lastIdentity) return;
    _lastIdentity = identity;
    final queueChanged = supportsQueue && queueJson != _currentQueueJson;
    if (queueChanged) {
      _currentQueueJson = queueJson;
      _queueRevision++;
    }
    final retryAt = _queueArtworkRetryAt;
    final retryArtwork = retryAt != null && !DateTime.now().isBefore(retryAt);
    if (queueChanged || retryArtwork) _queueArtworkRetryAt = null;
    final artworkIdentity = '$trackId\u0000$artworkUrl';
    // Transport/favorite updates must not cancel or duplicate an artwork load
    // that is already in progress for this same source.
    if (artworkIdentity != _currentArtworkIdentity) {
      _currentArtworkIdentity = artworkIdentity;
      _lastArtworkIdentity = null;
      _generation++;
    }
    final generation = _generation;
    unawaited(
      _publishSnapshot(
        generation: generation,
        trackId: trackId,
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        artworkIdentity: artworkIdentity,
        isPlaying: isPlaying,
        isLoading: isLoading,
        loadingLabel: loadingLabel,
        isFavorite: isFavorite,
        repeatMode: repeatMode,
        accentColor: accentColor,
        languageCode: languageCode,
        queueJson: queueChanged || retryArtwork ? queueJson : null,
        queueChanged: queueChanged,
        queueRevision: _queueRevision,
      ),
    );
  }

  String _encodeQueue(Iterable<Map<String, String>> queue, int currentIndex) {
    final count = queue.length;
    if (count == 0) return '[]';
    final focusedIndex = currentIndex >= 0 && currentIndex < count
        ? currentIndex
        : 0;
    // Keep the two tracks immediately before playback visible above the
    // current track, followed by the upcoming queue in its original order.
    final firstVisibleIndex = (focusedIndex - 2).clamp(0, focusedIndex).toInt();
    final rows = <Map<String, Object>>[];
    for (final (offset, entry)
        in queue.skip(firstVisibleIndex).take(100).indexed) {
      final index = firstVisibleIndex + offset;
      String compact(String key, [int maxLength = 160]) {
        final normalized = (entry[key] ?? '')
            .replaceAll(_queueWhitespace, ' ')
            .trim();
        return String.fromCharCodes(normalized.runes.take(maxLength));
      }

      final title = compact('title');
      final artist = compact('artist');
      final id = compact('id', 256);
      final artworkUrl = (entry['artworkUrl'] ?? '').trim();
      rows.add({
        'id': id.isEmpty ? '$title\u0000$artist' : id,
        'queueIndex': entry['queueIndex'] ?? '$index',
        'isCurrent': index == focusedIndex,
        'title': title,
        'artist': artist,
        if (artworkUrl.isNotEmpty) 'artworkUrl': artworkUrl,
      });
    }
    return jsonEncode(rows);
  }

  Future<void> _publishSnapshot({
    required int generation,
    required String? trackId,
    required String? title,
    required String? artist,
    required String? artworkUrl,
    required String artworkIdentity,
    required bool isPlaying,
    required bool isLoading,
    required String? loadingLabel,
    required bool isFavorite,
    required String repeatMode,
    required int accentColor,
    required String languageCode,
    required String? queueJson,
    required bool queueChanged,
    required int queueRevision,
  }) async {
    var ownsArtworkRequest = false;
    var updatedWidget = false;
    try {
      final updateData = <String, Object?>{
        'title': title ?? '',
        'trackId': trackId ?? title ?? '',
        'artist': artist ?? '',
        'isPlaying': isPlaying,
        'isLoading': isLoading,
        'loadingLabel': ?loadingLabel,
        'isFavorite': isFavorite,
        'repeatMode': repeatMode,
        'accentColor': accentColor,
        'languageCode': languageCode,
      };
      _currentWidgetData = updateData;
      await _channel.invokeMethod<void>('update', <String, Object?>{
        ...updateData,
        if (queueChanged) 'queueJson': queueJson,
      });
      updatedWidget = true;
      if (queueJson != null && queueRevision == _queueRevision) {
        unawaited(
          _publishCachedQueueArtworkPaths(
            queueJson: queueJson,
            queueRevision: queueRevision,
            publishProgress: queueChanged,
          ),
        );
      }
      if (generation != _generation ||
          artworkIdentity == _lastArtworkIdentity ||
          _artworkRequestGeneration == generation ||
          artworkUrl == null ||
          artworkUrl.isEmpty) {
        return;
      }
      _artworkRequestGeneration = generation;
      ownsArtworkRequest = true;
      final deviceAudioUri = deviceAudioUriFromArtworkSource(artworkUrl);
      if (deviceAudioUri != null) {
        final bytes = await const MethodChannel('bstream_music/local_audio')
            .invokeMethod<Uint8List>('loadArtwork', <String, Object>{
              'audioUri': deviceAudioUri,
              'targetWidth': 320,
            });
        if (generation == _generation && bytes != null && bytes.isNotEmpty) {
          await _channel.invokeMethod<void>(
            'updateArtworkBytes',
            <String, Object?>{
              'trackId': trackId ?? title ?? '',
              'bytes': bytes,
            },
          );
          if (generation == _generation) _lastArtworkIdentity = artworkIdentity;
        }
        return;
      }
      String? path;
      final uri = Uri.tryParse(artworkUrl);
      if (uri?.scheme == 'file') {
        path = uri!.toFilePath();
      } else if (uri?.scheme == 'http' || uri?.scheme == 'https') {
        final cached = await BStreamArtworkCacheManager().getSingleFile(
          artworkUrl,
        );
        path = cached.path;
      } else if (await File(artworkUrl).exists()) {
        path = artworkUrl;
      }
      if (generation != _generation || path == null) return;
      await _channel.invokeMethod<void>('updateArtwork', <String, Object?>{
        'trackId': trackId ?? title ?? '',
        'artworkPath': path,
      });
      if (generation == _generation) _lastArtworkIdentity = artworkIdentity;
    } on MissingPluginException {
      // No platform widgets in this build.
    } catch (error) {
      debugPrint('Home widget update failed: $error');
    } finally {
      if (!updatedWidget && queueRevision == _queueRevision) {
        if (queueChanged) _currentQueueJson = null;
        if (!queueChanged && queueJson != null) _deferQueueArtworkRetry();
      }
      if (ownsArtworkRequest && _artworkRequestGeneration == generation) {
        _artworkRequestGeneration = null;
      }
    }
  }

  Future<void> _publishCachedQueueArtworkPaths({
    required String queueJson,
    required int queueRevision,
    required bool publishProgress,
  }) async {
    var needsRetry = false;
    try {
      final entries = jsonDecode(queueJson);
      if (entries is! List || entries.isEmpty) return;
      final resolvedEntries = entries
          .map<Map<String, Object?>>((raw) {
            if (raw is! Map) return <String, Object?>{};
            final item = Map<String, Object?>.from(raw);
            // The launcher service needs an app-local path, not an HTTP URL.
            item.remove('artworkUrl');
            return item;
          })
          .toList(growable: false);
      var pathsAwaitingPublish = false;
      const batchSize = 4;
      const publishEvery = 8;
      for (var start = 0; start < entries.length; start += batchSize) {
        if (queueRevision != _queueRevision) return;
        final end = start + batchSize < entries.length
            ? start + batchSize
            : entries.length;
        final batch = await Future.wait(
          List.generate(end - start, (offset) async {
            final index = start + offset;
            final raw = entries[index];
            if (raw is! Map) return false;
            final source = raw['artworkUrl']?.toString().trim() ?? '';
            if (source.isEmpty) return false;
            final path = await _cachedQueueArtworkPath(
              source,
              allowNetworkDownload: true,
            );
            if (path == null) {
              needsRetry = true;
              return false;
            }
            resolvedEntries[index]['artworkPath'] = path;
            return true;
          }),
        );
        pathsAwaitingPublish |= batch.any((hasArtwork) => hasArtwork);

        final shouldPublish =
            end == entries.length ||
            (publishProgress && (start == 0 || end % publishEvery == 0));
        if (shouldPublish && pathsAwaitingPublish) {
          if (queueRevision != _queueRevision) return;
          await _channel.invokeMethod<void>('update', <String, Object?>{
            ..._currentWidgetData,
            'queueJson': jsonEncode(resolvedEntries),
          });
          pathsAwaitingPublish = false;
        }

        // Yield between groups so filling a long queue doesn't monopolize
        // cache I/O or issue a burst of image requests at once.
        if (end < entries.length) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }
    } on MissingPluginException {
      // Desktop builds do not include native home-screen widgets.
    } catch (error) {
      needsRetry = true;
      debugPrint('Home widget cached queue artwork lookup failed: $error');
    } finally {
      if (needsRetry && queueRevision == _queueRevision) {
        _deferQueueArtworkRetry();
      }
    }
  }

  void _deferQueueArtworkRetry() {
    _queueArtworkRetryAt = DateTime.now().add(_queueArtworkRetryDelay);
  }

  Future<String?> _cachedQueueArtworkPath(
    String source, {
    required bool allowNetworkDownload,
  }) async {
    final now = DateTime.now();
    final previous = _queueArtworkPathCache[source];
    if (previous != null) {
      final path = previous.path;
      if (path != null && await File(path).exists()) return path;
      if (path == null &&
          now.difference(previous.checkedAt) < _queueArtworkRetryDelay) {
        return null;
      }
    }

    String? path;
    try {
      final uri = Uri.tryParse(source);
      final deviceAudioUri = deviceAudioUriFromArtworkSource(source);
      if (deviceAudioUri != null) {
        final bytes = await const MethodChannel('bstream_music/local_audio')
            .invokeMethod<Uint8List>('loadArtwork', <String, Object>{
              'audioUri': deviceAudioUri,
              'targetWidth': 256,
            });
        if (bytes != null && bytes.isNotEmpty) {
          final directory = Directory.systemTemp;
          await directory.create(recursive: true);
          final filename = 'bstream_queue_${_stablePathHash(source)}.img';
          final file = File(
            '${directory.path}${Platform.pathSeparator}$filename',
          );
          await file.writeAsBytes(bytes, flush: true);
          if (await file.length() > 0) path = file.path;
        }
      } else if (uri?.scheme == 'file') {
        final candidate = uri!.toFilePath();
        if (await File(candidate).exists()) path = candidate;
      } else if (uri?.scheme == 'http' || uri?.scheme == 'https') {
        // Match the rendition keys used by visible artwork surfaces, then try
        // a few sensible fallbacks for YouTube thumbnails.
        final previewCandidates = youtubeThumbnailPreviewCandidates(source);
        final videoId = youtubeVideoIdFromThumbnailSource(source);
        final candidates = <String>{
          if (videoId != null) ...youtubeThumbnailCandidates(source).take(4),
          sizedGoogleArtworkSource(source, 256) ?? source,
          source,
          sizedGoogleArtworkSource(source, 128) ?? source,
          ...previewCandidates,
        };
        final cache = BStreamArtworkCacheManager();
        for (final candidate in candidates) {
          final cached = await cache.getFileFromCache(candidate);
          if (cached != null && await cached.file.exists()) {
            path = cached.file.path;
            break;
          }
        }
        if (path == null && allowNetworkDownload) {
          // Resolve missing artwork so songs farther down a large queue are
          // ready when they scroll into view. Requests run in small batches.
          final downloadCandidates = videoId != null
              ? previewCandidates.take(3)
              : candidates.take(3);
          for (final candidate in downloadCandidates) {
            try {
              final cached = await cache.getSingleFile(candidate);
              if (await cached.exists() && await cached.length() > 0) {
                path = cached.path;
                break;
              }
            } catch (_) {
              // Try the next known thumbnail rendition.
            }
          }
        }
      } else if (uri?.hasScheme != true && await File(source).exists()) {
        path = source;
      }
    } catch (_) {
      path = null;
    }
    _queueArtworkPathCache[source] = (path: path, checkedAt: now);
    if (_queueArtworkPathCache.length > 160) {
      _queueArtworkPathCache.remove(_queueArtworkPathCache.keys.first);
    }
    return path;
  }

  int _stablePathHash(String value) {
    var hash = 0x811C9DC5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  void dispose() {
    _generation++;
    _queueRevision++;
    _channel.setMethodCallHandler(null);
  }
}
