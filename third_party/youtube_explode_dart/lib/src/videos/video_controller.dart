import 'dart:convert';

import 'package:meta/meta.dart';

import '../../youtube_explode_dart.dart';
import '../reverse_engineering/pages/watch_page.dart';
import '../reverse_engineering/player/player_response.dart';

@internal
class VideoController {
  @protected
  final YoutubeHttpClient httpClient;

  VideoController(this.httpClient);

  Future<PlayerResponse> getPlayerResponse(
      VideoId videoId, YoutubeApiClient client,
      {WatchPage? watchPage, YoutubePoTokenContext? poToken}) async {
    final payload = client.payload;
    assert(payload['context'] != null, 'client must contain a context');
    assert(payload['context']!['client'] != null,
        'client must contain a context.client');

    final userAgent = payload['context']!['client']!['userAgent'] as String?;
    final ytCfg = watchPage?.ytCfg;

    final body = _copyMap(Map<Object?, Object?>.from(payload))
      ..addAll({
        'videoId': videoId.value,
        if (ytCfg?.containsKey('STS') ?? false)
          'playbackContext': {
            'contentPlaybackContext': {
              'html5Preference': 'HTML5_PREF_WANTS',
              'signatureTimestamp': ytCfg!['STS'].toString()
            }
          }
      });
    final context = body['context'] as Map<String, dynamic>;
    final contextClient = context['client'] as Map<String, dynamic>;
    var visitorData = poToken?.visitorData ?? _visitorDataFromConfig(ytCfg);
    if (contextClient['clientName'] == 'IOS' && visitorData == null) {
      visitorData = await _extractVisitorData(httpClient, client);
    }
    if (visitorData != null && visitorData.isNotEmpty) {
      contextClient['visitorData'] = visitorData;
    }
    final playerPoToken = poToken?.playerRequestPoToken;
    if (playerPoToken != null && playerPoToken.isNotEmpty) {
      body['serviceIntegrityDimensions'] = {'poToken': playerPoToken};
    }

    final content = await httpClient.postString(
      client.apiUrl,
      body: body,
      headers: {
        if (userAgent != null) 'User-Agent': userAgent,
        'X-Youtube-Client-Name': payload['context']!['client']!['clientName'],
        'X-Youtube-Client-Version':
            payload['context']!['client']!['clientVersion'],
        if (visitorData != null && visitorData.isNotEmpty)
          'X-Goog-Visitor-Id': visitorData,
        'Origin': 'https://www.youtube.com',
        'Sec-Fetch-Mode': 'navigate',
        'Content-Type': 'application/json',
        if (watchPage != null) 'Cookie': watchPage.cookieString,
        ...client.headers,
      },
    );
    return PlayerResponse.parse(content);
  }

  String? _visitorDataFromConfig(Map<String, dynamic>? ytCfg) {
    final value = ytCfg?['INNERTUBE_CONTEXT']?['client']?['visitorData'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Map<String, dynamic> _copyMap(Map<Object?, Object?> source) {
    return <String, dynamic>{
      for (final entry in source.entries)
        entry.key.toString(): _copyValue(entry.value),
    };
  }

  Object? _copyValue(Object? value) {
    if (value is Map) {
      return _copyMap(Map<Object?, Object?>.from(value));
    }
    if (value is List) {
      return value.map(_copyValue).toList(growable: true);
    }
    return value;
  }

  String? _visitorData;

  Future<String> _extractVisitorData(
      YoutubeHttpClient http, YoutubeApiClient client) async {
    if (_visitorData != null) {
      return _visitorData!;
    }

    var response =
        await http.getString('https://www.youtube.com/sw.js_data', headers: {
      'User-Agent': client.payload['context']['client']['userAgent']!,
      'Content-Type': 'application/json',
    });

    if (response.startsWith(")]}'")) {
      response = response.substring(4);
    }

    final data = json.decode(response) as List<dynamic>;
    final value = data[0][2][0][0][13];

    return _visitorData = value;
  }
}
