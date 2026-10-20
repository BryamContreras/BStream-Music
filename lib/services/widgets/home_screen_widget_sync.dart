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
  HomeScreenWidgetSync({MethodChannel? channel, this.onAction})
    : _channel = channel ?? const MethodChannel('bstream_music/home_widget') {
    _channel.setMethodCallHandler(_handleCall);
    unawaited(_registerAndConsumePendingAction());
  }

  final MethodChannel _channel;
  final Future<void> Function(String action)? onAction;
  int _generation = 0;
  int? _artworkRequestGeneration;
  String? _lastIdentity;
  String? _currentArtworkIdentity;
  String? _lastArtworkIdentity;
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
    required bool isFavorite,
    required String repeatMode,
    required int accentColor,
    required String languageCode,
    List<Map<String, String>> queue = const [],
    int currentQueueIndex = -1,
  }) {
    final queueJson = _encodeQueue(queue, currentQueueIndex);
    final identity =
        '$trackId\u0000$title\u0000$artist\u0000$artworkUrl\u0000'
        '$isPlaying\u0000$isFavorite\u0000$repeatMode\u0000'
        '$accentColor\u0000$languageCode\u0000$queueJson';
    if (identity == _lastIdentity) return;
    _lastIdentity = identity;
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
        isFavorite: isFavorite,
        repeatMode: repeatMode,
        accentColor: accentColor,
        languageCode: languageCode,
        queueJson: queueJson,
        snapshotIdentity: identity,
      ),
    );
  }

  String _encodeQueue(List<Map<String, String>> queue, int currentIndex) {
    if (queue.isEmpty) return '[]';
    final focusedIndex = currentIndex >= 0 && currentIndex < queue.length
        ? currentIndex
        : 0;
    final indexedQueue = queue
        .asMap()
        .entries
        .map((item) {
          return <String, String>{
            ...item.value,
            'queueIndex': item.value['queueIndex'] ?? '${item.key}',
          };
        })
        .toList(growable: false);
    final ordered = <Map<String, String>>[
      ...indexedQueue.skip(focusedIndex),
      ...indexedQueue.take(focusedIndex),
    ].take(100);
    return jsonEncode(
      ordered
          .map((entry) {
            String compact(String key, [int maxLength = 160]) {
              final normalized = (entry[key] ?? '')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim();
              return String.fromCharCodes(normalized.runes.take(maxLength));
            }

            final title = compact('title');
            final artist = compact('artist');
            final id = compact('id', 256);
            final artworkUrl = (entry['artworkUrl'] ?? '').trim();
            return <String, String>{
              'id': id.isEmpty ? '$title\u0000$artist' : id,
              'queueIndex': entry['queueIndex'] ?? '0',
              'title': title,
              'artist': artist,
              if (artworkUrl.isNotEmpty) 'artworkUrl': artworkUrl,
            };
          })
          .toList(growable: false),
    );
  }

  Future<void> _publishSnapshot({
    required int generation,
    required String? trackId,
    required String? title,
    required String? artist,
    required String? artworkUrl,
    required String artworkIdentity,
    required bool isPlaying,
    required bool isFavorite,
    required String repeatMode,
    required int accentColor,
    required String languageCode,
    required String queueJson,
    required String snapshotIdentity,
  }) async {
    var ownsArtworkRequest = false;
    try {
      final updateData = <String, Object?>{
        'title': title ?? '',
        'trackId': trackId ?? title ?? '',
        'artist': artist ?? '',
        'isPlaying': isPlaying,
        'isFavorite': isFavorite,
        'repeatMode': repeatMode,
        'accentColor': accentColor,
        'languageCode': languageCode,
        'queueJson': queueJson,
      };
      await _channel.invokeMethod<void>('update', updateData);
      unawaited(
        _publishCachedQueueArtworkPaths(
          updateData: updateData,
          queueJson: queueJson,
          generation: generation,
          artworkIdentity: artworkIdentity,
          snapshotIdentity: snapshotIdentity,
        ),
      );
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
      if (ownsArtworkRequest && _artworkRequestGeneration == generation) {
        _artworkRequestGeneration = null;
      }
    }
  }

  Future<void> _publishCachedQueueArtworkPaths({
    required Map<String, Object?> updateData,
    required String queueJson,
    required int generation,
    required String artworkIdentity,
    required String snapshotIdentity,
  }) async {
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
        if (!_isCurrentQueueArtworkRequest(
          generation,
          artworkIdentity,
          snapshotIdentity,
        )) {
          return;
        }
        final end = start + batchSize < entries.length
            ? start + batchSize
            : entries.length;
        final batch = await Future.wait(
          entries.sublist(start, end).asMap().entries.map((entry) async {
            final index = start + entry.key;
            final raw = entry.value;
            final item = resolvedEntries[index];
            if (raw is! Map) return (item: item, hasArtwork: false);
            final source = raw['artworkUrl']?.toString().trim() ?? '';
            if (source.isEmpty) return (item: item, hasArtwork: false);
            final path = await _cachedQueueArtworkPath(
              source,
              allowNetworkDownload: true,
            );
            if (path != null) {
              item['artworkPath'] = path;
              return (item: item, hasArtwork: true);
            }
            return (item: item, hasArtwork: false);
          }),
        );
        pathsAwaitingPublish |= batch.any((result) => result.hasArtwork);

        final shouldPublish =
            start == 0 || end == entries.length || end % publishEvery == 0;
        if (shouldPublish && pathsAwaitingPublish) {
          if (!_isCurrentQueueArtworkRequest(
            generation,
            artworkIdentity,
            snapshotIdentity,
          )) {
            return;
          }
          await _channel.invokeMethod<void>('update', <String, Object?>{
            ...updateData,
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
      debugPrint('Home widget cached queue artwork lookup failed: $error');
    }
  }

  bool _isCurrentQueueArtworkRequest(
    int generation,
    String artworkIdentity,
    String snapshotIdentity,
  ) =>
      generation == _generation &&
      artworkIdentity == _currentArtworkIdentity &&
      snapshotIdentity == _lastIdentity;

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
          now.difference(previous.checkedAt) < const Duration(seconds: 20)) {
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
              'targetWidth': 128,
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
          if (videoId != null) ...previewCandidates.skip(1).take(2),
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
          for (final candidate in candidates.take(3)) {
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
    _channel.setMethodCallHandler(null);
  }
}
