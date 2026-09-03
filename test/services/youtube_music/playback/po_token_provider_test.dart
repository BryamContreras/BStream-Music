import 'dart:async';
import 'dart:convert';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/youtube_music/innertube_transport.dart';
import 'package:bstream_music/services/youtube_music/playback/headless_inappwebview_runtime.dart';
import 'package:bstream_music/services/youtube_music/playback/javascript_runtime.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_binding.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BotGuardResponseParser', () {
    test('parses realistic ytcfg and escaped ytAtN homepage data', () {
      final result = BotGuardResponseParser.parseHomepage(
        _homepageFixture(
          visitorData: 'visitor-homepage',
          eventId: 'event-homepage',
        ),
      );

      expect(result.source, BotGuardBootstrapSource.homepage);
      expect(result.visitorData, 'visitor-homepage');
      expect(result.eventId, 'event-homepage');
      expect(result.youtubeConfig['EVENT_ID'], 'event-homepage');
      expect(result.challenge.globalName, 'BotGuardVm');
      expect(
        result.challenge.interpreterTrustedResourceUrl,
        '//www.google.com/js/th/interpreter.js',
      );
      expect(result.challenge.clientExperimentsStateBlob, 'experiments');
    });

    test('uses context visitorData when top-level value is absent', () {
      final result = BotGuardResponseParser.parseHomepage(
        _homepageFixture(
          visitorData: 'nested-visitor',
          eventId: 'event-id',
          visitorAtTopLevel: false,
        ),
      );

      expect(result.visitorData, 'nested-visitor');
    });

    test('requires EVENT_ID and rejects untrusted interpreter hosts', () {
      expect(
        () => BotGuardResponseParser.parseHomepage(
          _homepageFixture(visitorData: 'visitor', eventId: ''),
        ),
        throwsA(isA<PoTokenException>()),
      );
      expect(
        () => BotGuardResponseParser.parseTrustedInterpreterUri(
          'https://www.google.com.evil.test/interpreter.js',
        ),
        throwsA(isA<PoTokenException>()),
      );
    });

    test('parses att/get challenge and current Google interpreter URL', () {
      final challenge = BotGuardResponseParser.parseAttestation(
        jsonEncode(_attestationResponse()),
      );
      final uri = BotGuardResponseParser.parseTrustedInterpreterUri(
        challenge.interpreterTrustedResourceUrl,
      );

      expect(challenge.program, 'program');
      expect(uri, Uri.parse('https://www.google.com/js/th/interpreter.js'));
    });

    test('parses integrity TTL with expiry margin', () {
      final now = DateTime.utc(2026, 1, 1);
      final token = BotGuardResponseParser.parseIntegrityToken(
        jsonEncode(<Object>[
          base64Url.encode(<int>[1, 2, 3]),
          1200,
        ]),
        now: now,
      );

      expect(token.bytes, <int>[1, 2, 3]);
      expect(token.expiresAt, now.add(const Duration(minutes: 10)));
      expect(token.usesWebsafeFallback, isFalse);
    });

    test('parses a websafe fallback when WAA withholds integrity token', () {
      final token = BotGuardResponseParser.parseIntegrityToken(
        jsonEncode(<Object?>[null, 43200, null, 'fallback_websafe-123']),
        now: DateTime.utc(2026),
      );

      expect(token.bytes, isNull);
      expect(token.websafeFallbackToken, 'fallback_websafe-123');
      expect(token.usesWebsafeFallback, isTrue);
    });

    test('extracts fallback visitorData after an anti-XSSI prefix', () {
      final value = BotGuardResponseParser.parseVisitorData(
        ")]}'\n${jsonEncode(<String, Object>{
          'nested': <String, String>{'visitorData': 'visitor-123'},
        })}",
      );

      expect(value, 'visitor-123');
    });
  });

  group('HeadlessInAppWebViewJavaScriptRuntime', () {
    test('advertises Android, iOS, Windows and macOS only', () {
      expect(
        HeadlessInAppWebViewJavaScriptRuntime.supportsPlatform(
          AppPlatformType.ios,
        ),
        isTrue,
      );
      expect(
        HeadlessInAppWebViewJavaScriptRuntime.supportsPlatform(
          AppPlatformType.android,
        ),
        isTrue,
      );
      expect(
        HeadlessInAppWebViewJavaScriptRuntime.supportsPlatform(
          AppPlatformType.windows,
        ),
        isTrue,
      );
      expect(
        HeadlessInAppWebViewJavaScriptRuntime.supportsPlatform(
          AppPlatformType.macos,
        ),
        isTrue,
      );
      expect(
        HeadlessInAppWebViewJavaScriptRuntime.supportsPlatform(
          AppPlatformType.linux,
        ),
        isFalse,
      );
    });

    test('fails cleanly on Linux without invoking the plugin', () async {
      final runtime = HeadlessInAppWebViewJavaScriptRuntime(
        platform: AppPlatformType.linux,
      );

      await expectLater(
        runtime.initialize(),
        throwsA(isA<UnsupportedYoutubeJavaScriptRuntimeException>()),
      );
    });
  });

  group('BotGuardPoTokenProvider', () {
    test(
      'uses homepage identity, interpreter and current GenerateIT RPC',
      () async {
        final transport = _FakeBotGuardTransport();
        final runtimes = <_FakeBotGuardRuntime>[];
        final provider = BotGuardPoTokenProvider(
          transport: transport,
          runtimeFactory: () {
            final runtime = _FakeBotGuardRuntime();
            runtimes.add(runtime);
            return runtime;
          },
          assetLoader: (_) async => '<html></html>',
        );

        final values = await Future.wait(<Future<YoutubePoTokenData>>[
          provider.getTokens(videoId: 'video-1'),
          provider.getTokens(videoId: 'video-1'),
          provider.getTokens(videoId: 'video-1'),
        ]);
        final cached = await provider.getTokens(videoId: 'video-1');

        expect(
          values.map((value) => value.playerRequestPoToken).toSet(),
          hasLength(1),
        );
        expect(cached.visitorData, 'visitor-homepage');
        expect(transport.homepageCalls, 1);
        expect(transport.fallbackVisitorCalls, 0);
        expect(transport.attestationCalls, 0);
        expect(transport.interpreterCalls, 1);
        expect(transport.generateCalls, 1);
        expect(transport.compatibilityGenerateCalls, 0);
        expect(transport.lastGenerateHeaders['x-goog-api-key'], isNotEmpty);
        expect(
          transport.lastGenerateHeaders['x-user-agent'],
          'grpc-web-javascript/0.1',
        );
        expect(transport.lastGenerateBody, <Object>[
          BotGuardPoTokenProvider.requestKey,
          'snapshot-response',
        ]);
        expect(runtimes.single.config?['EVENT_ID'], 'event-homepage');
        expect(runtimes.single.mintedIdentifiers, <String>[
          'video-1',
          'visitor-homepage',
        ]);
      },
    );

    test(
      'retries the YouTube GenerateIT alias when the primary is degraded',
      () async {
        final transport = _FakeBotGuardTransport(
          primaryGenerateIsDegraded: true,
        );
        final runtime = _FakeBotGuardRuntime();
        final provider = BotGuardPoTokenProvider(
          transport: transport,
          runtimeFactory: () => runtime,
          assetLoader: (_) async => '<html></html>',
        );

        final result = await provider.getTokens(videoId: 'video-1');

        expect(result.usesWebsafeFallback, isFalse);
        expect(result.playerRequestPoToken, isNotEmpty);
        expect(result.streamingDataPoToken, isNotEmpty);
        expect(transport.generateCalls, 1);
        expect(transport.compatibilityGenerateCalls, 1);
        expect(runtime.disposed, isFalse);
      },
    );

    test(
      'rejects websafe fallback values without an integrity token',
      () async {
        final transport = _FakeBotGuardTransport(
          primaryGenerateIsDegraded: true,
          compatibilityGenerateIsDegraded: true,
        );
        final provider = BotGuardPoTokenProvider(
          transport: transport,
          runtimeFactory: _FakeBotGuardRuntime.new,
          assetLoader: (_) async => '<html></html>',
        );
        addTearDown(provider.dispose);

        await expectLater(
          provider.getTokens(videoId: 'video-1'),
          throwsA(isA<PoTokenException>()),
        );
        expect(transport.generateCalls, 2);
        expect(transport.compatibilityGenerateCalls, 2);
        expect(transport.attestationCalls, 1);
      },
    );

    test(
      'tries a coherent attestation bootstrap when homepage integrity is withheld',
      () async {
        final transport = _FakeBotGuardTransport(
          homepageGenerateIsDegraded: true,
        );
        final runtimes = <_FakeBotGuardRuntime>[];
        final provider = BotGuardPoTokenProvider(
          transport: transport,
          runtimeFactory: () {
            final runtime = _FakeBotGuardRuntime();
            runtimes.add(runtime);
            return runtime;
          },
          assetLoader: (_) async => '<html></html>',
        );
        addTearDown(provider.dispose);

        final result = await provider.getTokens(videoId: 'video-1');

        expect(result.visitorData, 'visitor-fallback');
        expect(result.usesWebsafeFallback, isFalse);
        expect(transport.homepageCalls, 1);
        expect(transport.fallbackVisitorCalls, 1);
        expect(transport.attestationCalls, 1);
        expect(transport.generateCalls, 2);
        expect(transport.compatibilityGenerateCalls, 1);
        expect(runtimes, hasLength(2));
        expect(runtimes.first.disposed, isTrue);
        expect(runtimes.last.disposed, isFalse);
      },
    );

    test('falls back coherently to sw visitorData plus att/get', () async {
      final transport = _FakeBotGuardTransport(homepageIsInvalid: true);
      final runtime = _FakeBotGuardRuntime();
      final provider = BotGuardPoTokenProvider(
        transport: transport,
        runtimeFactory: () => runtime,
        assetLoader: (_) async => '<html></html>',
      );

      final result = await provider.getTokens(videoId: 'video-1');

      expect(result.visitorData, 'visitor-fallback');
      expect(transport.homepageCalls, 1);
      expect(transport.fallbackVisitorCalls, 1);
      expect(transport.attestationCalls, 1);
      expect(transport.lastAttestationBody, <String, Object?>{
        'context': <String, Object?>{
          'client': <String, Object?>{
            'clientName': 'WEB',
            'clientVersion': '2.20990101.00.00',
            'visitorData': 'visitor-fallback',
          },
        },
        'engagementType': 'ENGAGEMENT_TYPE_UNBOUND',
      });
      expect(runtime.config?['VISITOR_DATA'], 'visitor-fallback');
    });

    test('rejects an interpreter redirected outside trusted hosts', () async {
      final runtime = _FakeBotGuardRuntime();
      final provider = BotGuardPoTokenProvider(
        transport: _FakeBotGuardTransport(
          interpreterEffectiveUri: Uri.parse(
            'https://attacker.example/interpreter.js',
          ),
        ),
        runtimeFactory: () => runtime,
        assetLoader: (_) async => '<html></html>',
      );

      await expectLater(
        provider.getTokens(videoId: 'video-1'),
        throwsA(isA<PoTokenException>()),
      );
      expect(runtime.disposed, isTrue);
    });

    test('models WEB_REMIX visitor binding for both token families', () async {
      final runtime = _FakeBotGuardRuntime();
      final provider = BotGuardPoTokenProvider(
        transport: _FakeBotGuardTransport(),
        runtimeFactory: () => runtime,
        assetLoader: (_) async => '<html></html>',
      );

      final result = await provider.getTokens(
        videoId: 'video-1',
        requirements: const YoutubePoTokenRequirements(
          player: true,
          gvs: true,
          playerBinding: YoutubePoTokenBinding.visitorData,
          gvsBinding: YoutubePoTokenBinding.visitorData,
        ),
      );

      expect(result.playerRequestPoToken, result.streamingDataPoToken);
      expect(result.playerBinding, YoutubePoTokenBinding.visitorData);
      expect(runtime.mintedIdentifiers, <String>['visitor-homepage']);
    });

    test('supports shared video-bound player and GVS mint', () async {
      final runtime = _FakeBotGuardRuntime();
      final provider = BotGuardPoTokenProvider(
        transport: _FakeBotGuardTransport(),
        runtimeFactory: () => runtime,
        assetLoader: (_) async => '<html></html>',
      );

      final result = await provider.getTokens(
        videoId: 'video-1',
        requirements: const YoutubePoTokenRequirements(
          player: true,
          gvs: true,
          gvsBinding: YoutubePoTokenBinding.videoId,
        ),
      );

      expect(result.playerRequestPoToken, result.streamingDataPoToken);
      expect(runtime.mintedIdentifiers, <String>['video-1']);
    });

    test(
      'recreates expired generator and refreshes homepage snapshot',
      () async {
        final clock = _MutableClock(DateTime.utc(2026));
        final transport = _FakeBotGuardTransport(ttlSeconds: 660);
        final runtimes = <_FakeBotGuardRuntime>[];
        final provider = BotGuardPoTokenProvider(
          transport: transport,
          runtimeFactory: () {
            final runtime = _FakeBotGuardRuntime();
            runtimes.add(runtime);
            return runtime;
          },
          assetLoader: (_) async => '<html></html>',
          clock: clock.call,
        );

        await provider.getTokens(videoId: 'video-1');
        clock.value = clock.value.add(const Duration(minutes: 2));
        await provider.getTokens(videoId: 'video-1');

        expect(transport.homepageCalls, 2);
        expect(transport.generateCalls, 2);
        expect(runtimes, hasLength(2));
        expect(runtimes.first.disposed, isTrue);
      },
    );

    test('bounds provider and per-generator mint caches', () async {
      final runtime = _FakeBotGuardRuntime();
      final provider = BotGuardPoTokenProvider(
        transport: _FakeBotGuardTransport(),
        runtimeFactory: () => runtime,
        assetLoader: (_) async => '<html></html>',
        maxTokenCacheEntries: 1,
        maxMintCacheEntries: 1,
      );
      const playerOnly = YoutubePoTokenRequirements(player: true, gvs: false);

      await provider.getTokens(videoId: 'video-1', requirements: playerOnly);
      await provider.getTokens(videoId: 'video-2', requirements: playerOnly);
      await provider.getTokens(videoId: 'video-1', requirements: playerOnly);

      expect(runtime.mintedIdentifiers, <String>[
        'video-1',
        'video-2',
        'video-1',
      ]);
    });

    test('configurable detector skips clients that need no token', () async {
      final transport = _FakeBotGuardTransport();
      final provider = BotGuardPoTokenProvider(
        transport: transport,
        runtimeFactory: _FakeBotGuardRuntime.new,
        assetLoader: (_) async => '<html></html>',
        requirementDetector: (request) => request.clientName == 'NO_PO'
            ? YoutubePoTokenRequirements.none
            : YoutubePoTokenRequirements.both,
      );

      final result = await provider.getTokensIfRequired(
        videoId: 'video-1',
        clientName: 'NO_PO',
      );

      expect(result, isNull);
      expect(transport.totalCalls, 0);
    });

    test(
      'dispose cancels an invalidated flight before allocating a runtime',
      () async {
        final homepageStarted = Completer<void>();
        final homepageRelease = Completer<void>();
        final transport = _FakeBotGuardTransport(
          homepageStarted: homepageStarted,
          homepageRelease: homepageRelease,
        );
        final runtime = _FakeBotGuardRuntime();
        var runtimeFactoryCalls = 0;
        final provider = BotGuardPoTokenProvider(
          transport: transport,
          runtimeFactory: () {
            runtimeFactoryCalls += 1;
            return runtime;
          },
          assetLoader: (_) async => '<html></html>',
        );

        final tokens = provider.getTokens(videoId: 'video-1');
        await homepageStarted.future;
        final disposing = provider.dispose();
        homepageRelease.complete();

        await expectLater(tokens, throwsA(isA<PoTokenCancelledException>()));
        await disposing;
        expect(runtimeFactoryCalls, 0);
        expect(runtime.disposed, isFalse);
      },
    );

    test('one cancelled observer cannot abort a shared token flight', () async {
      final homepageStarted = Completer<void>();
      final homepageRelease = Completer<void>();
      var current = true;
      final transport = _FakeBotGuardTransport(
        homepageStarted: homepageStarted,
        homepageRelease: homepageRelease,
      );
      final runtime = _FakeBotGuardRuntime();
      final provider = BotGuardPoTokenProvider(
        transport: transport,
        runtimeFactory: () => runtime,
        assetLoader: (_) async => '<html></html>',
      );

      final tokens = provider.getTokens(
        videoId: 'video-1',
        shouldContinue: () => current,
      );
      await homepageStarted.future;
      final surviving = provider.getTokens(videoId: 'video-1');
      current = false;
      homepageRelease.complete();

      await expectLater(tokens, throwsA(isA<PoTokenCancelledException>()));
      final result = await surviving;
      expect(result.streamingDataPoToken, isNotEmpty);
      expect(transport.homepageCalls, 1);
      expect(transport.fallbackVisitorCalls, 0);
      expect(transport.interpreterCalls, 1);
      expect(transport.generateCalls, 1);
      expect(runtime.disposed, isFalse);
      await provider.dispose();
      expect(runtime.disposed, isTrue);
    });

    test(
      'bundled harness configures identity before BotGuard operations',
      () async {
        final html = await rootBundle.loadString(
          'assets/youtube/po_token.html',
        );

        expect(html, contains('function configureBotGuard'));
        expect(html, contains('window.yt.config_ = youtubeConfig'));
        expect(html, contains('function runBotGuard'));
        expect(html, contains('function createPoTokenMinter'));
        expect(html, contains('function obtainPoToken'));
        expect(html, contains('var loggerFunctions = ['));
        expect(html, contains('vmTelemetryCallback'));
        expect(html, contains('window.__bstreamSynchronousSnapshot'));
      },
    );
  });
}

Map<String, Object?> _attestationResponse() => <String, Object?>{
  'responseContext': <String, Object?>{},
  'bgChallenge': <String, Object?>{
    'interpreterUrl': <String, String>{
      'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue':
          '//www.google.com/js/th/interpreter.js',
    },
    'interpreterHash': 'interpreter-hash',
    'program': 'program',
    'globalName': 'BotGuardVm',
    'clientExperimentsStateBlob': 'experiments',
  },
};

String _homepageFixture({
  required String visitorData,
  required String eventId,
  bool visitorAtTopLevel = true,
}) {
  final config = <String, Object?>{
    'EVENT_ID': eventId,
    if (visitorAtTopLevel) 'VISITOR_DATA': visitorData,
    'INNERTUBE_CONTEXT': <String, Object?>{
      'client': <String, Object?>{
        'clientName': 'WEB',
        'clientVersion': '2.20260817.01.00',
        'visitorData': visitorData,
      },
    },
  };
  final response = jsonEncode(_attestationResponse());
  final escaped = utf8.encode(response).map((byte) {
    return '\\x${byte.toRadixString(16).padLeft(2, '0')}';
  }).join();
  return '''
    <script>ytcfg.set(${jsonEncode(config)});</script>
    <script>window.ytAtN({'R': '$escaped', 'T': 'ignored',});</script>
  ''';
}

String _homepageWithoutChallengeFixture() =>
    '''
  <script>ytcfg.set(${jsonEncode(<String, Object?>{
      'INNERTUBE_CONTEXT_CLIENT_VERSION': '2.20990101.00.00',
      'INNERTUBE_CONTEXT': <String, Object?>{
        'client': <String, Object?>{'clientName': 'WEB', 'clientVersion': '2.20990101.00.00'},
      },
    })});</script>
''';

class _FakeBotGuardRuntime implements YoutubeJavaScriptRuntime {
  final mintedIdentifiers = <String>[];
  Map<String, Object?>? config;
  bool disposed = false;

  @override
  Future<void> initialize({
    String html = YoutubeJavaScriptRuntime.emptyDocument,
    Uri? baseUrl,
  }) async {}

  @override
  Future<Object?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const <String, dynamic>{},
    Duration? timeout,
  }) async {
    if (functionBody.contains('configureBotGuard(youtubeConfig)')) {
      config = Map<String, Object?>.from(arguments['youtubeConfig'] as Map);
      return true;
    }
    if (functionBody.contains('runBotGuard(challengeData)')) {
      final challenge = arguments['challengeData'] as Map;
      final interpreter = challenge['interpreterJavascript'] as Map;
      expect(
        interpreter['privateDoNotAccessOrElseSafeScriptWrappedValue'],
        contains('globalThis.Vm'),
      );
      return config?['VISITOR_DATA'] == 'visitor-fallback'
          ? 'snapshot-fallback'
          : 'snapshot-response';
    }
    if (functionBody.contains('createPoTokenMinter')) return true;
    if (functionBody.contains('obtainPoToken')) {
      final bytes = (arguments['identifierBytes'] as List).cast<int>();
      mintedIdentifiers.add(utf8.decode(bytes));
      return bytes;
    }
    throw StateError('Unexpected JavaScript call.');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeBotGuardTransport implements InnerTubeTransport {
  _FakeBotGuardTransport({
    this.ttlSeconds = 3600,
    this.homepageIsInvalid = false,
    this.primaryGenerateIsDegraded = false,
    this.compatibilityGenerateIsDegraded = false,
    this.homepageGenerateIsDegraded = false,
    this.homepageStarted,
    this.homepageRelease,
    this.interpreterEffectiveUri,
  });

  final int ttlSeconds;
  final bool homepageIsInvalid;
  final bool primaryGenerateIsDegraded;
  final bool compatibilityGenerateIsDegraded;
  final bool homepageGenerateIsDegraded;
  final Completer<void>? homepageStarted;
  final Completer<void>? homepageRelease;
  final Uri? interpreterEffectiveUri;
  int homepageCalls = 0;
  int fallbackVisitorCalls = 0;
  int attestationCalls = 0;
  int interpreterCalls = 0;
  int generateCalls = 0;
  int compatibilityGenerateCalls = 0;
  Object? lastAttestationBody;
  Object? lastGenerateBody;
  Map<String, String> lastGenerateHeaders = const <String, String>{};

  int get totalCalls =>
      homepageCalls +
      fallbackVisitorCalls +
      attestationCalls +
      interpreterCalls +
      generateCalls +
      compatibilityGenerateCalls;

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    if (uri == BotGuardPoTokenProvider.homepageUri) {
      homepageCalls += 1;
      if (homepageStarted?.isCompleted == false) homepageStarted!.complete();
      await homepageRelease?.future;
      return InnerTubeHttpResponse(
        statusCode: 200,
        body: homepageIsInvalid
            ? _homepageWithoutChallengeFixture()
            : _homepageFixture(
                visitorData: 'visitor-homepage',
                eventId: 'event-homepage',
              ),
      );
    }
    if (uri == BotGuardPoTokenProvider.fallbackVisitorDataUri) {
      fallbackVisitorCalls += 1;
      return const InnerTubeHttpResponse(
        statusCode: 200,
        body: '{"visitorData":"visitor-fallback"}',
      );
    }
    if (uri.host == 'www.google.com') {
      interpreterCalls += 1;
      return InnerTubeHttpResponse(
        statusCode: 200,
        body: 'globalThis.Vm={a:function(){}};',
        effectiveUri: interpreterEffectiveUri,
      );
    }
    throw StateError('Unexpected GET $uri');
  }

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) async {
    if (uri == BotGuardPoTokenProvider.attestationUri) {
      attestationCalls += 1;
      lastAttestationBody = body;
      expect(headers['x-goog-visitor-id'], 'visitor-fallback');
      return InnerTubeHttpResponse(
        statusCode: 200,
        body: jsonEncode(_attestationResponse()),
      );
    }
    if (uri == BotGuardPoTokenProvider.generateIntegrityTokenUri) {
      generateCalls += 1;
      lastGenerateBody = body;
      lastGenerateHeaders = headers;
      if (primaryGenerateIsDegraded ||
          (homepageGenerateIsDegraded && _isHomepageGenerate(body))) {
        return InnerTubeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<Object?>[null, ttlSeconds, null, 'fallback-token']),
        );
      }
      return InnerTubeHttpResponse(
        statusCode: 200,
        body: jsonEncode(<Object>[
          base64Url.encode(<int>[9, 8, 7]).replaceAll('=', ''),
          ttlSeconds,
        ]),
      );
    }
    if (uri == BotGuardPoTokenProvider.generateIntegrityTokenCompatibilityUri) {
      compatibilityGenerateCalls += 1;
      lastGenerateBody = body;
      lastGenerateHeaders = headers;
      if (compatibilityGenerateIsDegraded ||
          (homepageGenerateIsDegraded && _isHomepageGenerate(body))) {
        return InnerTubeHttpResponse(
          statusCode: 200,
          body: jsonEncode(<Object?>[null, ttlSeconds, null, 'fallback-token']),
        );
      }
      return InnerTubeHttpResponse(
        statusCode: 200,
        body: jsonEncode(<Object>[
          base64Url.encode(<int>[9, 8, 7]).replaceAll('=', ''),
          ttlSeconds,
        ]),
      );
    }
    throw StateError('Unexpected POST $uri');
  }

  @override
  void close() {}

  bool _isHomepageGenerate(Object body) =>
      body is List && body.length > 1 && body[1] == 'snapshot-response';
}

class _MutableClock {
  _MutableClock(this.value);

  DateTime value;

  DateTime call() => value;
}
