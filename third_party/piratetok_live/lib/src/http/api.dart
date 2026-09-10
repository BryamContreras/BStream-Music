import 'dart:convert';
import 'dart:async';
import 'dart:io';

import '../cancellation.dart';
import '../errors.dart';
import 'ua.dart';

class RoomIdResult {
  final String roomId;
  final bool reportedLive;
  final String? ttwid;

  const RoomIdResult(this.roomId, {this.reportedLive = true, this.ttwid});

  RoomIdResult withTtwid(String? value) => RoomIdResult(
    roomId,
    reportedLive: reportedLive,
    ttwid: value == null || value.isEmpty ? ttwid : value,
  );
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

/// Resolve an active TikTok LIVE room using independent TikTok web sources.
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
  final elapsed = Stopwatch()..start();
  RoomIdResult? apiCandidate;
  (Object, StackTrace)? apiFailure;
  final aliveResults = <String, bool>{};

  Future<bool> confirmAlive(String roomId) async {
    final cached = aliveResults[roomId];
    if (cached != null) return cached;
    final result = await _fetchRoomAlive(
      roomId,
      timeout: _stageTimeout(_remaining(timeout, elapsed), 4),
      proxy: proxy,
      userAgent: ua,
      language: lang,
      region: reg,
      cancellationToken: cancellationToken,
    );
    aliveResults[roomId] = result;
    return result;
  }

  try {
    try {
      apiCandidate = await _fetchRoomFromApi(
        clean,
        timeout: _stageTimeout(_remaining(timeout, elapsed), 7),
        proxy: proxy,
        userAgent: ua,
        language: lang,
        region: reg,
        cancellationToken: cancellationToken,
      );
      if (apiCandidate.reportedLive) return apiCandidate;

      // TikTok occasionally changes the status enum while leaving a valid room
      // ID. The independent alive endpoint prevents that from becoming a false
      // offline result while still rejecting stale room IDs.
      try {
        if (await confirmAlive(apiCandidate.roomId)) {
          return apiCandidate;
        }
      } on Object {
        if (cancellationToken?.isCancelled ?? false) rethrow;
        // The creator page below is the final independent fallback.
      }
    } on Object catch (error, stackTrace) {
      if (cancellationToken?.isCancelled ?? false) rethrow;
      apiFailure = (error, stackTrace);
    }

    try {
      final pageCandidate = await _fetchRoomFromLivePage(
        clean,
        timeout: _remaining(timeout, elapsed),
        proxy: proxy,
        userAgent: ua,
        language: lang,
        region: reg,
        cancellationToken: cancellationToken,
      );
      if (pageCandidate.reportedLive) return pageCandidate;
      try {
        if (await confirmAlive(pageCandidate.roomId)) {
          return pageCandidate;
        }
      } on Object {
        if (cancellationToken?.isCancelled ?? false) rethrow;
      }
      throw HostNotOnlineError(clean);
    } on Object catch (pageError, pageStackTrace) {
      if (cancellationToken?.isCancelled ?? false) rethrow;
      if (pageError is HostNotOnlineError || pageError is UserNotFoundError) {
        Error.throwWithStackTrace(pageError, pageStackTrace);
      }
      if (apiCandidate != null) throw HostNotOnlineError(clean);
      final failure = apiFailure;
      if (failure != null) {
        Error.throwWithStackTrace(failure.$1, failure.$2);
      }
      Error.throwWithStackTrace(pageError, pageStackTrace);
    }
  } finally {
    elapsed.stop();
  }
}

Future<RoomIdResult> _fetchRoomFromApi(
  String username, {
  required Duration timeout,
  required String proxy,
  required String userAgent,
  required String language,
  required String region,
  required CancellationToken? cancellationToken,
}) async {
  final params = {
    'aid': '1988',
    'app_name': 'tiktok_web',
    'device_platform': 'web_pc',
    'app_language': language,
    'browser_language': '$language-$region',
    'user_is_login': 'false',
    'sourceType': '54',
    'staleTime': '600000',
    'uniqueId': username,
  };
  final uri = Uri.https('www.tiktok.com', '/api-live/user/room', params);
  final client = HttpClient();
  StreamSubscription<void>? cancellationSubscription;
  try {
    _configureProxy(client, proxy);
    client.connectionTimeout = timeout;
    cancellationSubscription = _cancelClientOnSignal(client, cancellationToken);

    final request = await client.getUrl(uri).timeout(timeout);
    _setTikTokHeaders(
      request,
      userAgent: userAgent,
      language: language,
      region: region,
    );
    final response = await request.close().timeout(timeout);
    final httpStatus = response.statusCode;
    final ttwid = _ttwidFrom(response.cookies);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    return parseRoomLookupResponse(
      body,
      username: username,
      httpStatus: httpStatus,
    ).withTtwid(ttwid);
  } finally {
    await cancellationSubscription?.cancel();
    client.close(force: true);
  }
}

Future<RoomIdResult> _fetchRoomFromLivePage(
  String username, {
  required Duration timeout,
  required String proxy,
  required String userAgent,
  required String language,
  required String region,
  required CancellationToken? cancellationToken,
}) async {
  final uri = Uri.parse(
    'https://www.tiktok.com/@${Uri.encodeComponent(username)}/live',
  );
  final client = HttpClient();
  StreamSubscription<void>? cancellationSubscription;
  try {
    _configureProxy(client, proxy);
    client.connectionTimeout = timeout;
    cancellationSubscription = _cancelClientOnSignal(client, cancellationToken);
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = true;
    _setTikTokHeaders(
      request,
      userAgent: userAgent,
      language: language,
      region: region,
    );
    final response = await request.close().timeout(timeout);
    final httpStatus = response.statusCode;
    final ttwid = _ttwidFrom(response.cookies);
    final html = await response.transform(utf8.decoder).join().timeout(timeout);
    if (httpStatus == 403 || httpStatus == 429) {
      throw TikTokBlockedError(httpStatus);
    }
    return parseLiveRoomHtml(html, username: username).withTtwid(ttwid);
  } finally {
    await cancellationSubscription?.cancel();
    client.close(force: true);
  }
}

Future<bool> _fetchRoomAlive(
  String roomId, {
  required Duration timeout,
  required String proxy,
  required String userAgent,
  required String language,
  required String region,
  required CancellationToken? cancellationToken,
}) async {
  final uri = Uri.https('webcast.tiktok.com', '/webcast/room/check_alive/', {
    'aid': '1988',
    'region': region,
    'room_ids': roomId,
    'user_is_login': 'false',
  });
  final client = HttpClient();
  StreamSubscription<void>? cancellationSubscription;
  try {
    _configureProxy(client, proxy);
    client.connectionTimeout = timeout;
    cancellationSubscription = _cancelClientOnSignal(client, cancellationToken);
    final request = await client.getUrl(uri).timeout(timeout);
    _setTikTokHeaders(
      request,
      userAgent: userAgent,
      language: language,
      region: region,
    );
    final response = await request.close().timeout(timeout);
    final httpStatus = response.statusCode;
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (httpStatus == 403 || httpStatus == 429) {
      throw TikTokBlockedError(httpStatus);
    }
    return parseRoomAliveResponse(body, roomId: roomId);
  } finally {
    await cancellationSubscription?.cancel();
    client.close(force: true);
  }
}

RoomIdResult parseRoomLookupResponse(
  String body, {
  required String username,
  int httpStatus = 200,
}) {
  final result = _decodeObject(body, httpStatus: httpStatus);
  final statusCode =
      _intValue(result['statusCode'] ?? result['status_code']) ?? -1;
  final message = '${result['message'] ?? ''}'.toLowerCase();
  if (statusCode == 19881007 || message == 'user_not_found') {
    throw UserNotFoundError(username);
  }
  if (statusCode != 0) throw TikTokApiError(statusCode);

  final data = _stringMap(result['data']) ?? const <String, dynamic>{};
  final user = _stringMap(data['user']) ?? const <String, dynamic>{};
  final roomId = '${user['roomId'] ?? user['room_id'] ?? ''}'.trim();
  if (roomId.isEmpty || roomId == '0') throw HostNotOnlineError(username);

  final liveRoom = _stringMap(data['liveRoom'] ?? data['live_room']);
  final liveStatus = _intValue(liveRoom?['status']);
  final userStatus = _intValue(user['status']);
  return RoomIdResult(roomId, reportedLive: liveStatus == 2 || userStatus == 2);
}

RoomIdResult parseLiveRoomHtml(String html, {required String username}) {
  final marker = html.indexOf('id="SIGI_STATE"');
  final alternateMarker = marker < 0 ? html.indexOf("id='SIGI_STATE'") : marker;
  if (alternateMarker < 0) {
    throw TikTokBlockedError(200);
  }
  final jsonStart = html.indexOf('>', alternateMarker) + 1;
  final jsonEnd = html.indexOf('</script>', jsonStart);
  if (jsonStart <= 0 || jsonEnd < jsonStart) throw TikTokBlockedError(200);
  final blob = _decodeObject(
    html.substring(jsonStart, jsonEnd),
    httpStatus: 200,
  );
  final liveRoom = _stringMap(blob['LiveRoom']);
  if (liveRoom == null) throw UserNotFoundError(username);
  final liveRoomUserInfo = _stringMap(liveRoom['liveRoomUserInfo']);
  final user = _stringMap(liveRoomUserInfo?['user']);
  if (user == null) throw TikTokBlockedError(200);
  final roomId = '${user['roomId'] ?? user['room_id'] ?? ''}'.trim();
  if (roomId.isEmpty || roomId == '0') throw HostNotOnlineError(username);
  return RoomIdResult(roomId, reportedLive: _intValue(user['status']) == 2);
}

bool parseRoomAliveResponse(String body, {required String roomId}) {
  final result = _decodeObject(body, httpStatus: 200);
  final statusCode =
      _intValue(result['status_code'] ?? result['statusCode']) ?? -1;
  if (statusCode != 0) throw TikTokApiError(statusCode);
  final data = result['data'];
  if (data is! List) throw TikTokApiError(-1);
  for (final value in data) {
    final entry = _stringMap(value);
    if (entry == null) continue;
    final candidate = '${entry['room_id_str'] ?? entry['room_id'] ?? ''}';
    if (candidate != roomId) continue;
    final alive = entry['alive'];
    if (alive is bool) return alive;
    if ('$alive'.toLowerCase() == 'true' || '$alive' == '1') return true;
    if ('$alive'.toLowerCase() == 'false' || '$alive' == '0') return false;
  }
  throw TikTokApiError(-1);
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

void _configureProxy(HttpClient client, String proxy) {
  if (proxy.isEmpty) return;
  final proxyUri = Uri.parse(proxy);
  client.findProxy = (_) => 'PROXY ${proxyUri.host}:${proxyUri.port}';
}

void _setTikTokHeaders(
  HttpClientRequest request, {
  required String userAgent,
  required String language,
  required String region,
}) {
  request.headers.set(HttpHeaders.userAgentHeader, userAgent);
  request.headers.set(
    HttpHeaders.acceptLanguageHeader,
    '$language-$region,$language;q=0.9',
  );
  request.headers.set(HttpHeaders.refererHeader, 'https://www.tiktok.com/');
}

Map<String, dynamic> _decodeObject(String source, {required int httpStatus}) {
  if (httpStatus == 403 || httpStatus == 429) {
    throw TikTokBlockedError(httpStatus);
  }
  try {
    final value = json.decode(source);
    final result = _stringMap(value);
    if (result != null) return result;
  } on FormatException {
    // Converted below to a transport/block response with the HTTP status.
  }
  throw TikTokBlockedError(httpStatus);
}

Map<String, dynamic>? _stringMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, item) => MapEntry(key.toString(), item));
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

String? _ttwidFrom(List<Cookie> cookies) {
  for (final cookie in cookies) {
    final value = cookie.value.trim();
    if (cookie.name == 'ttwid' && value.length >= 16) return value;
  }
  return null;
}

Duration _remaining(Duration timeout, Stopwatch elapsed) {
  final value = timeout - elapsed.elapsed;
  if (value <= Duration.zero) {
    throw TimeoutException(
      'Timed out while resolving TikTok LIVE room.',
      timeout,
    );
  }
  return value;
}

Duration _stageTimeout(Duration remaining, int maximumSeconds) {
  final maximum = Duration(seconds: maximumSeconds);
  return remaining < maximum ? remaining : maximum;
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
