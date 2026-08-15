import 'dart:convert';
import 'dart:io';

import '../errors.dart';
import 'ua.dart';

class SigiProfile {
  final String userId;
  final String uniqueId;
  final String nickname;
  final String bio;
  final String avatarThumb;
  final String avatarMedium;
  final String avatarLarge;
  final bool verified;
  final bool privateAccount;
  final bool isOrganization;
  final String roomId;
  final String? bioLink;
  final int followerCount;
  final int followingCount;
  final int heartCount;
  final int videoCount;
  final int friendCount;

  const SigiProfile({
    this.userId = '',
    this.uniqueId = '',
    this.nickname = '',
    this.bio = '',
    this.avatarThumb = '',
    this.avatarMedium = '',
    this.avatarLarge = '',
    this.verified = false,
    this.privateAccount = false,
    this.isOrganization = false,
    this.roomId = '',
    this.bioLink,
    this.followerCount = 0,
    this.followingCount = 0,
    this.heartCount = 0,
    this.videoCount = 0,
    this.friendCount = 0,
  });
}

const _sigiMarker = 'id="__UNIVERSAL_DATA_FOR_REHYDRATION__"';

/// Scrape a TikTok profile page and extract profile data from the SIGI JSON.
/// Stateless — no caching. Use ProfileCache for cached access.
Future<SigiProfile> scrapeProfile(
  String username,
  String ttwid, {
  Duration timeout = const Duration(seconds: 15),
  String proxy = '',
  String? userAgent,
  String cookies = '',
  String? language,
  String? region,
}) async {
  final ua = userAgent ?? randomUa();
  final lang = language ?? systemLanguage();
  final reg = region ?? systemRegion();
  final clean = username.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  final cookieHeader = _buildCookie(ttwid, cookies);

  final client = HttpClient();
  try {
    if (proxy.isNotEmpty) {
      final proxyUri = Uri.parse(proxy);
      client.findProxy = (_) => 'PROXY ${proxyUri.host}:${proxyUri.port}';
    }
    client.connectionTimeout = timeout;

    final request = await client.getUrl(
      Uri.parse('https://www.tiktok.com/@$clean'),
    );
    request.headers.set('User-Agent', ua);
    request.headers.set('Cookie', cookieHeader);
    request.headers.set('Accept-Language', '$lang-$reg,$lang;q=0.9');

    final response = await request.close().timeout(timeout);
    final html = await response.transform(utf8.decoder).join();

    return _parseSigi(html, clean);
  } finally {
    client.close();
  }
}

SigiProfile _parseSigi(String html, String username) {
  final markerPos = html.indexOf(_sigiMarker);
  if (markerPos < 0) throw ProfileScrapeError('SIGI script tag not found');

  final gtPos = html.indexOf('>', markerPos);
  if (gtPos < 0) throw ProfileScrapeError('no > after SIGI marker');

  final jsonStart = gtPos + 1;
  final scriptEnd = html.indexOf('</script>', jsonStart);
  if (scriptEnd < 0) throw ProfileScrapeError('no </script> after SIGI JSON');

  final jsonStr = html.substring(jsonStart, scriptEnd);
  if (jsonStr.isEmpty) throw ProfileScrapeError('empty SIGI JSON blob');

  final blob = json.decode(jsonStr) as Map<String, dynamic>;
  final scope = blob['__DEFAULT_SCOPE__'] as Map<String, dynamic>?;
  if (scope == null) throw ProfileScrapeError('missing __DEFAULT_SCOPE__');

  final detail = scope['webapp.user-detail'] as Map<String, dynamic>?;
  if (detail == null) throw ProfileScrapeError('missing webapp.user-detail');

  final statusCode = (detail['statusCode'] as int?) ?? 0;
  switch (statusCode) {
    case 0:
      break;
    case 10222:
      throw ProfilePrivateError(username);
    case 10221:
    case 10223:
      throw ProfileNotFoundError(username);
    default:
      throw ProfileError(statusCode);
  }

  final userInfo = detail['userInfo'] as Map<String, dynamic>? ?? {};
  final user = userInfo['user'] as Map<String, dynamic>?;
  if (user == null) throw ProfileScrapeError('missing userInfo.user');
  final stats = userInfo['stats'] as Map<String, dynamic>? ?? {};

  String? bioLink;
  final bioLinkObj = user['bioLink'] as Map<String, dynamic>?;
  if (bioLinkObj != null) {
    final link = bioLinkObj['link'] as String?;
    if (link != null && link.isNotEmpty) bioLink = link;
  }

  return SigiProfile(
    userId: '${user['id'] ?? ''}',
    uniqueId: (user['uniqueId'] as String?) ?? '',
    nickname: (user['nickname'] as String?) ?? '',
    bio: (user['signature'] as String?) ?? '',
    avatarThumb: (user['avatarThumb'] as String?) ?? '',
    avatarMedium: (user['avatarMedium'] as String?) ?? '',
    avatarLarge: (user['avatarLarger'] as String?) ?? '',
    verified: user['verified'] == true,
    privateAccount: user['privateAccount'] == true,
    isOrganization: (user['isOrganization'] as int? ?? 0) != 0,
    roomId: (user['roomId'] as String?) ?? '',
    bioLink: bioLink,
    followerCount: (stats['followerCount'] as int?) ?? 0,
    followingCount: (stats['followingCount'] as int?) ?? 0,
    heartCount: (stats['heartCount'] as int?) ?? 0,
    videoCount: (stats['videoCount'] as int?) ?? 0,
    friendCount: (stats['friendCount'] as int?) ?? 0,
  );
}

String _buildCookie(String ttwid, String extra) {
  final base = 'ttwid=$ttwid';
  if (extra.isEmpty) return base;
  final filtered = extra
      .split('; ')
      .where((p) => !p.startsWith('ttwid='))
      .join('; ');
  return filtered.isEmpty ? base : '$base; $filtered';
}
