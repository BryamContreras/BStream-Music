import 'dart:async';
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
  String? _lastIdentity;
  String? _lastArtworkIdentity;

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
  }) {
    final identity =
        '$trackId\u0000$title\u0000$artist\u0000$artworkUrl\u0000'
        '$isPlaying\u0000$isFavorite\u0000$repeatMode\u0000'
        '$accentColor\u0000$languageCode';
    if (identity == _lastIdentity) return;
    _lastIdentity = identity;
    final artworkIdentity = '$trackId\u0000$artworkUrl';
    final needsArtwork = artworkIdentity != _lastArtworkIdentity;
    final generation = ++_generation;
    unawaited(
      _publishSnapshot(
        generation: generation,
        trackId: trackId,
        title: title,
        artist: artist,
        artworkUrl: artworkUrl,
        artworkIdentity: artworkIdentity,
        needsArtwork: needsArtwork,
        isPlaying: isPlaying,
        isFavorite: isFavorite,
        repeatMode: repeatMode,
        accentColor: accentColor,
        languageCode: languageCode,
      ),
    );
  }

  Future<void> _publishSnapshot({
    required int generation,
    required String? trackId,
    required String? title,
    required String? artist,
    required String? artworkUrl,
    required String artworkIdentity,
    required bool needsArtwork,
    required bool isPlaying,
    required bool isFavorite,
    required String repeatMode,
    required int accentColor,
    required String languageCode,
  }) async {
    try {
      await _channel.invokeMethod<void>('update', <String, Object?>{
        'title': title ?? '',
        'trackId': trackId ?? title ?? '',
        'artist': artist ?? '',
        'isPlaying': isPlaying,
        'isFavorite': isFavorite,
        'repeatMode': repeatMode,
        'accentColor': accentColor,
        'languageCode': languageCode,
        'artworkPath': '',
      });
      if (generation != _generation ||
          !needsArtwork ||
          artworkUrl == null ||
          artworkUrl.isEmpty) {
        return;
      }
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
    }
  }

  void dispose() {
    _generation++;
    _channel.setMethodCallHandler(null);
  }
}
