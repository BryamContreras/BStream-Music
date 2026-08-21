import 'dart:async';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../../../platform_channels/android_ytdl_channel.dart';

/// Supplies Web/WEB_REMIX PO tokens from Android's native BotGuard WebView.
/// Tokens are held only in memory and cached per video until their server TTL.
class AndroidWebPoTokenProvider implements YoutubePoTokenProvider {
  AndroidWebPoTokenProvider({AndroidYtdlChannel? channel})
    : _channel = channel ?? AndroidYtdlChannel();

  static const _warmupVideoId = 'jNQXAC9IVRw';
  final AndroidYtdlChannel _channel;
  final _cache = <String, AndroidPoTokenData>{};
  final _inFlight = <String, Future<AndroidPoTokenData?>>{};
  bool _disposed = false;

  @override
  Future<YoutubePoTokenContext?> getToken(
    VideoId videoId,
    YoutubeApiClient client,
  ) async {
    if (_disposed || !_isWebClient(client)) {
      return null;
    }
    final data = await _load(videoId.value);
    if (data == null) {
      return null;
    }
    return YoutubePoTokenContext(
      visitorData: data.visitorData,
      playerRequestPoToken: data.playerRequestPoToken,
      streamingDataPoToken: data.streamingDataPoToken,
      expiresAt: data.expiresAt,
    );
  }

  Future<void> prewarm() async {
    if (_disposed) {
      return;
    }
    try {
      await _load(_warmupVideoId);
    } catch (_) {}
  }

  Future<AndroidPoTokenData?> _load(String videoId) {
    final cached = _cache[videoId];
    if (cached != null &&
        cached.expiresAt.isAfter(
          DateTime.now().add(const Duration(minutes: 10)),
        )) {
      return Future<AndroidPoTokenData?>.value(cached);
    }
    return _inFlight[videoId] ??= _loadUncached(videoId).whenComplete(() {
      _inFlight.remove(videoId);
    });
  }

  Future<AndroidPoTokenData?> _loadUncached(String videoId) async {
    try {
      final data = await _channel.getPoTokens(videoId);
      if (data != null &&
          data.expiresAt.isAfter(
            DateTime.now().add(const Duration(minutes: 10)),
          )) {
        _cache[videoId] = data;
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  bool _isWebClient(YoutubeApiClient client) {
    final context = client.payload['context'];
    if (context is! Map) {
      return false;
    }
    final innerClient = context['client'];
    if (innerClient is! Map) {
      return false;
    }
    final name = innerClient['clientName']?.toString();
    return name == 'WEB' || name == 'WEB_REMIX';
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cache.clear();
    _inFlight.clear();
    unawaited(_channel.disposePoTokens());
  }
}
