import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/po_token.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/youtube_http_client.dart';
import 'package:youtube_explode_dart/src/videos/streams/stream_client.dart';
import 'package:youtube_explode_dart/src/videos/video_id.dart';
import 'package:youtube_explode_dart/src/videos/youtube_api_client.dart';

void main() {
  test('injects player and GVS PO token context', () async {
    Map<String, dynamic>? playerBody;
    final httpClient = YoutubeHttpClient(
      MockClient((request) async {
        if (request.method == 'POST') {
          playerBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'playabilityStatus': {'status': 'OK'},
              'videoDetails': {'videoId': 'abcdefghijk'},
              'streamingData': {
                'adaptiveFormats': [
                  {
                    'itag': 140,
                    'url': 'https://media.example/audio?clen=100',
                    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                    'bitrate': 128000,
                    'contentLength': '100',
                    'qualityLabel': 'audio',
                  },
                ],
              },
            }),
            200,
            request: request,
          );
        }
        if (request.method == 'HEAD') {
          expect(request.url.queryParameters['pot'], 'stream-token');
          return http.Response(
            '',
            200,
            headers: {'content-length': '100'},
            request: request,
          );
        }
        throw StateError('Unexpected ${request.method} request.');
      }),
    );
    addTearDown(httpClient.close);

    final client = YoutubeApiClient(
      {
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': 'test',
            'userAgent': 'BStream test',
          },
        },
      },
      'https://example.com/player',
    );
    final tokenProvider = _FakePoTokenProvider();
    final streamClient = StreamClient(
      httpClient,
      poTokenProvider: tokenProvider,
    );

    final manifest = await streamClient.getManifest(
      VideoId('abcdefghijk'),
      ytClients: [client],
      requireWatchPage: false,
    );

    expect(playerBody?['context']['client']['visitorData'], 'visitor-data');
    expect(
      playerBody?['serviceIntegrityDimensions']['poToken'],
      'player-token',
    );
    expect(
        manifest.audioOnly.single.url.queryParameters['pot'], 'stream-token');
    expect(tokenProvider.calls, 1);
  });

  test('skips streams with relative URLs when injecting PO token', () async {
    Map<String, dynamic>? playerBody;
    final httpClient = YoutubeHttpClient(
      MockClient((request) async {
        if (request.method == 'POST') {
          playerBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'playabilityStatus': {'status': 'OK'},
              'videoDetails': {'videoId': 'abcdefghijk'},
              'streamingData': {
                'adaptiveFormats': [
                  {
                    'itag': 140,
                    'url': '?pot=already-has-pot',
                    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                    'bitrate': 128000,
                    'contentLength': '100',
                    'qualityLabel': 'audio',
                  },
                  {
                    'itag': 251,
                    'url': 'https://media.example/audio.opus',
                    'mimeType': 'audio/webm; codecs="opus"',
                    'bitrate': 160000,
                    'contentLength': '200',
                    'qualityLabel': 'audio',
                  },
                ],
              },
            }),
            200,
            request: request,
          );
        }
        if (request.method == 'HEAD') {
          final url = request.url;
          expect(url.host, isNotEmpty, reason: 'Valid URL must have a host');
          if (url.host.isNotEmpty) {
            return http.Response('', 200, headers: {'content-length': '200'});
          }
        }
        throw StateError('Unexpected ${request.method} request.');
      }),
    );
    addTearDown(httpClient.close);

    final client = YoutubeApiClient(
      {
        'context': {
          'client': {
            'clientName': 'WEB',
            'clientVersion': 'test',
            'userAgent': 'BStream test',
          },
        },
      },
      'https://example.com/player',
    );
    final tokenProvider = _FakePoTokenProvider();
    final streamClient = StreamClient(
      httpClient,
      poTokenProvider: tokenProvider,
    );

    final manifest = await streamClient.getManifest(
      VideoId('abcdefghijk'),
      ytClients: [client],
      requireWatchPage: false,
    );

    expect(manifest.audioOnly, hasLength(1));
    expect(manifest.audioOnly.first.tag, 251);
    expect(manifest.audioOnly.first.url.host, 'media.example');
    expect(
      manifest.audioOnly.first.url.queryParameters['pot'],
      'stream-token',
    );
    expect(
      playerBody?['serviceIntegrityDimensions']['poToken'],
      'player-token',
    );
  });
}

class _FakePoTokenProvider implements YoutubePoTokenProvider {
  var calls = 0;

  @override
  void dispose() {}

  @override
  Future<YoutubePoTokenContext?> getToken(
    VideoId videoId,
    YoutubeApiClient client,
  ) async {
    calls++;
    return YoutubePoTokenContext(
      visitorData: 'visitor-data',
      playerRequestPoToken: 'player-token',
      streamingDataPoToken: 'stream-token',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }
}
