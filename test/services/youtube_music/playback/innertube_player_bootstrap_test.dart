import 'dart:async';

import 'package:bstream_music/services/youtube_music/innertube_transport.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_player_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses one coherent visitor, player, STS and embed snapshot', () {
    final result = InnerTubePlayerBootstrapParser.parse(r'''
      <script>
      ytcfg.set({"VISITOR_DATA":"visitor-123","STS":20348,
        "PLAYER_JS_URL":"\/s\/player\/abcd\/base.js",
        "encryptedHostFlags":"flags-123",
        "INNERTUBE_CONTEXT_CLIENT_NAME":56,
        "INNERTUBE_CONTEXT_CLIENT_VERSION":"2.20260831.01.00",
        "INNERTUBE_CONTEXT":{"client":{
          "clientName":"WEB_EMBEDDED_PLAYER",
          "clientVersion":"2.20260831.01.00"},
          "thirdParty":{"embeddedPlayerContext":{
            "embeddedPlayerEncryptedContext":"embedded-context"}}}});
      </script>
    ''');

    expect(result.visitorData, 'visitor-123');
    expect(
      result.playerUrl,
      Uri.parse('https://www.youtube.com/s/player/abcd/base.js'),
    );
    expect(result.signatureTimestamp, 20348);
    expect(result.encryptedHostFlags, 'flags-123');
    expect(result.clientName, 'WEB_EMBEDDED_PLAYER');
    expect(result.clientId, 56);
    expect(result.clientVersion, '2.20260831.01.00');
    expect(result.embeddedPlayerEncryptedContext, 'embedded-context');
  });

  test('rejects a player URL outside the YouTube HTTPS origin', () {
    expect(
      () => InnerTubePlayerBootstrapParser.parse(
        r'{"PLAYER_JS_URL":"https://evil.test/base.js"}',
      ),
      throwsA(isA<InnerTubePlayerBootstrapException>()),
    );
  });

  test('coalesces snapshots and forces a fresh embedded bootstrap', () async {
    final transport = _BootstrapTransport();
    final source = InnerTubePlayerBootstrapper(transport: transport);

    final values = await Future.wait(<Future<InnerTubePlayerBootstrap>>[
      source.load('dQw4w9WgXcQ'),
      source.load('dQw4w9WgXcQ'),
    ]);
    expect(values.map((value) => value.visitorData), everyElement('visitor-1'));
    expect(transport.requests, hasLength(1));

    final embedded = await source.load(
      'dQw4w9WgXcQ',
      embedded: true,
      forceRefresh: true,
    );
    expect(embedded.encryptedHostFlags, 'embed-flags');
    expect(embedded.clientName, 'WEB_EMBEDDED_PLAYER');
    expect(embedded.clientId, 56);
    expect(embedded.clientVersion, '2.20260831.01.00');
    expect(embedded.embeddedPlayerEncryptedContext, 'embedded-context');
    expect(transport.requests, hasLength(2));
    expect(transport.requests.last.uri.path, '/embed/dQw4w9WgXcQ');
    expect(
      transport.requests.last.headers['referer'],
      'https://www.reddit.com/',
    );
  });

  test(
    'invalidate prevents an older in-flight load from repopulating cache',
    () async {
      final transport = _ControlledBootstrapTransport();
      final source = InnerTubePlayerBootstrapper(transport: transport);

      final stale = source.load('dQw4w9WgXcQ');
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(1));

      source.invalidate();
      final fresh = source.load('dQw4w9WgXcQ');
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(2));

      transport.complete(1, 'visitor-fresh');
      expect((await fresh).visitorData, 'visitor-fresh');
      transport.complete(0, 'visitor-stale');
      expect((await stale).visitorData, 'visitor-stale');

      final cached = await source.load('dQw4w9WgXcQ');
      expect(cached.visitorData, 'visitor-fresh');
      expect(transport.requests, hasLength(2));
    },
  );
}

final class _BootstrapRequest {
  const _BootstrapRequest(this.uri, this.headers);

  final Uri uri;
  final Map<String, String> headers;
}

final class _BootstrapTransport implements InnerTubeTransport {
  final List<_BootstrapRequest> requests = <_BootstrapRequest>[];

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    requests.add(_BootstrapRequest(uri, headers));
    final embedded = uri.path.startsWith('/embed/');
    return InnerTubeHttpResponse(
      statusCode: 200,
      body:
          '{"VISITOR_DATA":"visitor-${requests.length}",'
          '"STS":20348,'
          '"PLAYER_JS_URL":"/s/player/abcd/base.js"'
          '${embedded ? ',"encryptedHostFlags":"embed-flags",'
                    '"INNERTUBE_CONTEXT_CLIENT_NAME":56,'
                    '"INNERTUBE_CONTEXT_CLIENT_VERSION":"2.20260831.01.00",'
                    '"INNERTUBE_CONTEXT":{"client":{'
                    '"clientName":"WEB_EMBEDDED_PLAYER",'
                    '"clientVersion":"2.20260831.01.00"},'
                    '"thirdParty":{"embeddedPlayerContext":{'
                    '"embeddedPlayerEncryptedContext":"embedded-context"}}}' : ''}}',
      effectiveUri: uri,
    );
  }

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) => throw UnimplementedError();

  @override
  void close() {}
}

final class _ControlledBootstrapTransport implements InnerTubeTransport {
  final List<({Uri uri, Completer<InnerTubeHttpResponse> response})> requests =
      <({Uri uri, Completer<InnerTubeHttpResponse> response})>[];

  void complete(int index, String visitorData) {
    final request = requests[index];
    request.response.complete(
      InnerTubeHttpResponse(
        statusCode: 200,
        body:
            '{"VISITOR_DATA":"$visitorData",'
            '"STS":20348,'
            '"PLAYER_JS_URL":"/s/player/abcd/base.js"}',
        effectiveUri: request.uri,
      ),
    );
  }

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) {
    final response = Completer<InnerTubeHttpResponse>();
    requests.add((uri: uri, response: response));
    return response.future;
  }

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) => throw UnimplementedError();

  @override
  void close() {}
}
