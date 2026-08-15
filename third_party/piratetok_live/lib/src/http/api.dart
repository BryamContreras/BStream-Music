import 'dart:convert';
import 'dart:async';
import 'dart:io';

import '../cancellation.dart';
import '../errors.dart';
import 'ua.dart';

class RoomIdResult {
  final String roomId;
  const RoomIdResult(this.roomId);
}

class StreamUrls {
  final String flvOrigin;
  final String flvHd;
  final String flvSd;
  final String flvLd;
  final String flvAudio;

  const StreamUrls({
    this.flvOrigin = '',
    this.flvHd = '',
    this.flvSd = '',
    this.flvLd = '',
    this.flvAudio = '',
  });
}

class RoomInfo {
  final String title;
  final int viewers;
  final int likes;
  final int totalUser;
  final StreamUrls? streamUrl;

  const RoomInfo({
    this.title = '',
    this.viewers = 0,
    this.likes = 0,
    this.totalUser = 0,
    this.streamUrl,
  });
}

/// Check if a TikTok user is currently live. Returns room ID.
Future<RoomIdResult> checkOnline(
  String username, {
  Duration timeout = const Duration(seconds: 10),
  String proxy = '',
  String? userAgent,
  String? language,
  String? region,
  CancellationToken? cancellationToken,
}) async {
  final ua = userAgent ?? randomUa();
  final lang = language ?? systemLanguage();
  final reg = region ?? systemRegion();
  final clean = username.trim().replaceFirst(RegExp(r'^@'), '');
  final params = {
    'aid': '1988',
    'app_name': 'tiktok_web',
    'device_platform': 'web_pc',
    'app_language': lang,
    'browser_language': '$lang-$reg',
    'user_is_login': 'false',
    'sourceType': '54',
    'staleTime': '600000',
    'uniqueId': clean,
  };

  final uri = Uri.https('www.tiktok.com', '/api-live/user/room', params);
  final client = HttpClient();
  StreamSubscription<void>? cancellationSubscription;
  try {
    if (proxy.isNotEmpty) {
      final proxyUri = Uri.parse(proxy);
      client.findProxy = (_) => 'PROXY ${proxyUri.host}:${proxyUri.port}';
    }
    client.connectionTimeout = timeout;
    cancellationSubscription = _cancelClientOnSignal(client, cancellationToken);

    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set('User-Agent', ua);
    final response = await request.close().timeout(timeout);
    final httpStatus = response.statusCode;

    if (httpStatus == 403 || httpStatus == 429) {
      await response.drain<void>().timeout(timeout);
      throw TikTokBlockedError(httpStatus);
    }

    final body = await response.transform(utf8.decoder).join().timeout(timeout);

    final Map<String, dynamic> result;
    try {
      result = json.decode(body) as Map<String, dynamic>;
    } on FormatException {
      throw TikTokBlockedError(httpStatus);
    }

    final statusCode = result['statusCode'] as int? ?? -1;
    if (statusCode == 19881007) throw UserNotFoundError(clean);
    if (statusCode != 0) throw TikTokApiError(statusCode);

    final data = result['data'] as Map<String, dynamic>? ?? {};
    final user = data['user'] as Map<String, dynamic>? ?? {};
    final roomId = '${user['roomId'] ?? ''}';

    if (roomId.isEmpty || roomId == '0') throw HostNotOnlineError(clean);

    final liveRoom = data['liveRoom'] as Map<String, dynamic>? ?? {};
    final liveStatus = liveRoom['status'] as int? ?? 0;
    final userStatus = user['status'] as int? ?? 0;
    if (liveStatus != 2 && userStatus != 2) throw HostNotOnlineError(clean);

    return RoomIdResult(roomId);
  } finally {
    await cancellationSubscription?.cancel();
    client.close(force: true);
  }
}

/// Fetch room metadata. Needs cookies for 18+ rooms.
Future<RoomInfo> fetchRoomInfo(
  String roomId, {
  Duration timeout = const Duration(seconds: 10),
  String cookies = '',
  String proxy = '',
  String? userAgent,
  String? language,
  String? region,
  CancellationToken? cancellationToken,
}) async {
  final ua = userAgent ?? randomUa();
  final lang = language ?? systemLanguage();
  final reg = region ?? systemRegion();
  final tz = systemTimezone();
  final params = {
    'aid': '1988',
    'app_name': 'tiktok_web',
    'device_platform': 'web_pc',
    'app_language': lang,
    'browser_language': '$lang-$reg',
    'browser_name': 'Mozilla',
    'browser_online': 'true',
    'browser_platform': 'Linux x86_64',
    'cookie_enabled': 'true',
    'screen_height': '1080',
    'screen_width': '1920',
    'tz_name': tz,
    'webcast_language': lang,
    'room_id': roomId,
  };

  final uri = Uri.https('webcast.tiktok.com', '/webcast/room/info/', params);
  final client = HttpClient();
  StreamSubscription<void>? cancellationSubscription;
  try {
    if (proxy.isNotEmpty) {
      final proxyUri = Uri.parse(proxy);
      client.findProxy = (_) => 'PROXY ${proxyUri.host}:${proxyUri.port}';
    }
    client.connectionTimeout = timeout;
    cancellationSubscription = _cancelClientOnSignal(client, cancellationToken);

    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set('User-Agent', ua);
    request.headers.set('Referer', 'https://www.tiktok.com/');
    if (cookies.isNotEmpty) {
      request.headers.set('Cookie', cookies);
    }

    final response = await request.close().timeout(timeout);
    final httpStatus = response.statusCode;

    if (httpStatus == 403 || httpStatus == 429) {
      await response.drain<void>().timeout(timeout);
      throw TikTokBlockedError(httpStatus);
    }

    final bodyStr = await response
        .transform(utf8.decoder)
        .join()
        .timeout(timeout);
    final body = json.decode(bodyStr) as Map<String, dynamic>;
    final sc = body['status_code'] as int? ?? -1;

    if (sc == 4003110) throw const AgeRestrictedError();
    if (sc != 0) throw TikTokApiError(sc);

    final data = body['data'] as Map<String, dynamic>? ?? {};
    final stats = data['stats'] as Map<String, dynamic>? ?? {};

    return RoomInfo(
      title: '${data['title'] ?? ''}',
      viewers: (data['user_count'] as int?) ?? 0,
      likes: (stats['like_count'] as int?) ?? 0,
      totalUser: (stats['total_user'] as int?) ?? 0,
      streamUrl: _parseStreamUrls(data['stream_url']),
    );
  } finally {
    await cancellationSubscription?.cancel();
    client.close(force: true);
  }
}

StreamSubscription<void>? _cancelClientOnSignal(
  HttpClient client,
  CancellationToken? cancellationToken,
) {
  if (cancellationToken == null) return null;
  if (cancellationToken.isCancelled) {
    client.close(force: true);
    throw const HttpException('TikTok request cancelled.');
  }
  final subscription = cancellationToken.onCancel.listen((_) {
    client.close(force: true);
  });
  if (cancellationToken.isCancelled) {
    unawaited(subscription.cancel());
    client.close(force: true);
    throw const HttpException('TikTok request cancelled.');
  }
  return subscription;
}

StreamUrls? _parseStreamUrls(dynamic raw) {
  if (raw is! Map<String, dynamic>) return null;
  final flv = raw['flv_pull_url'];
  if (flv is! Map<String, dynamic> || flv.isEmpty) return null;
  return StreamUrls(
    flvOrigin: '${flv['FULL_HD1'] ?? ''}',
    flvHd: '${flv['HD1'] ?? ''}',
    flvSd: '${flv['SD1'] ?? ''}',
    flvLd: '${flv['SD2'] ?? ''}',
    flvAudio: '${flv['AUDIO'] ?? ''}',
  );
}
