import 'dart:math';

import '../http/ua.dart';

String buildWssUrl(
  String cdnHost,
  String roomId, {
  String? language,
  String? region,
}) {
  final rng = Random();
  final lastRtt = (100 + rng.nextDouble() * 100).toStringAsFixed(3);
  final tz = systemTimezone();
  final lang = language ?? systemLanguage();
  final reg = region ?? systemRegion();

  final params = {
    'version_code': '180800',
    'device_platform': 'web',
    'cookie_enabled': 'true',
    'screen_width': '1920',
    'screen_height': '1080',
    'browser_language': '$lang-$reg',
    'browser_platform': 'Linux x86_64',
    'browser_name': 'Mozilla',
    'browser_version': '5.0 (X11)',
    'browser_online': 'true',
    'tz_name': tz,
    'app_name': 'tiktok_web',
    'sup_ws_ds_opt': '1',
    'update_version_code': '2.0.0',
    'compress': 'gzip',
    'webcast_language': lang,
    'ws_direct': '1',
    'aid': '1988',
    'live_id': '12',
    'app_language': lang,
    'client_enter': '1',
    'room_id': roomId,
    'identity': 'audience',
    'history_comment_count': '6',
    'last_rtt': lastRtt,
    'heartbeat_duration': '10000',
    'resp_content_type': 'protobuf',
    'did_rule': '3',
  };

  final query = params.entries
      .map(
        (e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
      )
      .join('&');

  return 'wss://$cdnHost/webcast/im/ws_proxy/ws_reuse_supplement/?$query';
}
