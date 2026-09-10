// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:piratetok_live/src/auth/ttwid.dart';
import 'package:piratetok_live/src/client.dart';
import 'package:piratetok_live/src/connection/raw_ws.dart';
import 'package:piratetok_live/src/errors.dart';
import 'package:piratetok_live/src/http/api.dart';

void main() {
  group('TikTok anonymous device bootstrap', () {
    test('uses the registration route and preserves encoded ttwid', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? method;
      String? userAgent;
      String? language;
      String? origin;
      String? body;
      server.listen((request) async {
        method = request.method;
        userAgent = request.headers.value(HttpHeaders.userAgentHeader);
        language = request.headers.value(HttpHeaders.acceptLanguageHeader);
        origin = request.headers.value('origin');
        body = await utf8.decoder.bind(request).join();
        request.response.headers.add(
          HttpHeaders.setCookieHeader,
          'ttwid=1%7Cregistered-device-token-123456789; Path=/; HttpOnly',
        );
        await request.response.close();
      });

      try {
        final value = await fetchTtwid(
          timeout: const Duration(seconds: 3),
          userAgent: 'BStream-Test-UA',
          language: 'es',
          region: 'NI',
          registrationUri: _serverUri(server, '/ttwid/register/'),
          bootstrapUris: const [],
        );

        expect(value, '1%7Cregistered-device-token-123456789');
        expect(method, 'POST');
        expect(userAgent, 'BStream-Test-UA');
        expect(language, 'es-NI,es;q=0.9');
        expect(origin, 'https://www.tiktok.com');
        expect(jsonDecode(body!)['aid'], 1988);
        expect(jsonDecode(body!)['service'], 'www.tiktok.com');
      } finally {
        await server.close(force: true);
      }
    });

    test(
      'falls back across live pages when registration has no cookie',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <String>[];
        final userAgents = <String?>[];
        server.listen((request) async {
          requests.add('${request.method} ${request.uri.path}');
          userAgents.add(request.headers.value(HttpHeaders.userAgentHeader));
          await request.drain<void>();
          if (request.uri.path == '/live') {
            request.response.headers.add(
              HttpHeaders.setCookieHeader,
              'ttwid=1%7Clive-page-device-token-987654321; Path=/; HttpOnly',
            );
          }
          await request.response.close();
        });

        try {
          final value = await fetchTtwid(
            timeout: const Duration(seconds: 3),
            userAgent: 'Stable-Session-UA',
            registrationUri: _serverUri(server, '/register'),
            bootstrapUris: [
              _serverUri(server, '/creator/live'),
              _serverUri(server, '/live'),
              _serverUri(server, '/'),
            ],
          );

          expect(value, '1%7Clive-page-device-token-987654321');
          expect(requests, [
            'POST /register',
            'GET /creator/live',
            'GET /live',
          ]);
          expect(userAgents, everyElement('Stable-Session-UA'));
        } finally {
          await server.close(force: true);
        }
      },
    );

    test('rejects empty and malformed cookie responses', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.add(
          HttpHeaders.setCookieHeader,
          'ttwid=short; Path=/',
        );
        await request.response.close();
      });

      try {
        await expectLater(
          fetchTtwid(
            timeout: const Duration(seconds: 3),
            registrationUri: _serverUri(server, '/register'),
            bootstrapUris: [_serverUri(server, '/live')],
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('usable anonymous device cookie'),
            ),
          ),
        );
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('TikTok room resolution payloads', () {
    test('accepts current live status and keeps the room id', () {
      final result = parseRoomLookupResponse(
        jsonEncode({
          'statusCode': 0,
          'data': {
            'user': {'roomId': '7654321', 'status': 2},
            'liveRoom': {'status': 2},
          },
        }),
        username: 'creator',
      );

      expect(result.roomId, '7654321');
      expect(result.reportedLive, isTrue);
    });

    test('retains a stale-status room for independent alive checking', () {
      final result = parseRoomLookupResponse(
        jsonEncode({
          'statusCode': 0,
          'data': {
            'user': {'roomId': '7654321', 'status': 4},
            'liveRoom': {'status': 4},
          },
        }),
        username: 'creator',
      );

      expect(result.roomId, '7654321');
      expect(result.reportedLive, isFalse);
    });

    test('parses live and offline SIGI_STATE creator pages', () {
      String htmlFor(int status) =>
          '<html><script id="SIGI_STATE" type="application/json">'
          '${jsonEncode({
            'LiveRoom': {
              'liveRoomUserInfo': {
                'user': {'uniqueId': 'creator', 'roomId': '99887766', 'status': status},
              },
            },
          })}'
          '</script></html>';

      expect(
        parseLiveRoomHtml(htmlFor(2), username: 'creator').reportedLive,
        isTrue,
      );
      final offline = parseLiveRoomHtml(htmlFor(4), username: 'creator');
      expect(offline.roomId, '99887766');
      expect(offline.reportedLive, isFalse);
    });

    test('parses the independent room alive response', () {
      String response(bool alive) => jsonEncode({
        'status_code': 0,
        'data': [
          {'room_id': 99887766, 'room_id_str': '99887766', 'alive': alive},
        ],
      });

      expect(
        parseRoomAliveResponse(response(true), roomId: '99887766'),
        isTrue,
      );
      expect(
        parseRoomAliveResponse(response(false), roomId: '99887766'),
        isFalse,
      );
    });

    test('distinguishes an unknown user from a blocked response', () {
      expect(
        () => parseRoomLookupResponse(
          jsonEncode({'statusCode': 19881007}),
          username: 'missing',
        ),
        throwsA(isA<UserNotFoundError>()),
      );
      expect(
        () => parseLiveRoomHtml('<html>captcha</html>', username: 'creator'),
        throwsA(isA<TikTokBlockedError>()),
      );
    });
  });

  test('CDN fallback is stable, regional, and duplicate-free', () {
    expect(tiktokCdnCandidates('webcast-ws.tiktok.com', region: 'NI'), [
      'webcast-ws.tiktok.com',
      'webcast-ws.us.tiktok.com',
      'webcast-ws.eu.tiktok.com',
    ]);
    expect(tiktokCdnCandidates('webcast-ws.tiktok.com', region: 'ES'), [
      'webcast-ws.tiktok.com',
      'webcast-ws.eu.tiktok.com',
      'webcast-ws.us.tiktok.com',
    ]);
  });

  test('WebSocket rejection separates cookie refresh from CDN failure', () {
    expect(
      classifyTikTokWebSocketUpgradeFailure('HTTP/1.1 200 OK', const {
        'handshake-status': '417',
        'handshake-msg': 'http: named cookie not present',
      }),
      isA<InvalidTtwidError>(),
    );
    expect(
      classifyTikTokWebSocketUpgradeFailure(
        'HTTP/1.1 415 Unsupported Media Type',
        const {},
      ),
      isA<DeviceBlockedError>(),
    );
    expect(
      classifyTikTokWebSocketUpgradeFailure(
        'HTTP/1.1 503 Service Unavailable',
        const {},
      ),
      isA<SocketException>(),
    );
  });
}

Uri _serverUri(HttpServer server, String path) => Uri(
  scheme: 'http',
  host: server.address.address,
  port: server.port,
  path: path,
);
