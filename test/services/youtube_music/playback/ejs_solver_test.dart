import 'dart:convert';

import 'package:bstream_music/services/youtube_music/innertube_transport.dart';
import 'package:bstream_music/services/youtube_music/playback/ejs_solver.dart';
import 'package:bstream_music/services/youtube_music/playback/javascript_runtime.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteEjsModuleSource', () {
    test('verifies pinned hashes and coalesces concurrent loads', () async {
      final transport = _FakeTransport(<Uri, InnerTubeHttpResponse>{
        Uri.parse('https://example.test/lib.js'): const InnerTubeHttpResponse(
          statusCode: 200,
          body: 'var lib = {};',
        ),
        Uri.parse('https://example.test/core.js'): const InnerTubeHttpResponse(
          statusCode: 200,
          body: 'function jsc() {}',
        ),
      });
      final source = RemoteEjsModuleSource(
        transport: transport,
        modules: <EjsModuleSpec>[
          _spec('lib', 'https://example.test/lib.js', 'var lib = {};'),
          _spec('core', 'https://example.test/core.js', 'function jsc() {}'),
        ],
      );

      final results = await Future.wait(<Future<String>>[
        source.load(),
        source.load(),
        source.load(),
      ]);

      expect(results.toSet(), hasLength(1));
      expect(results.first, contains('Object.assign(globalThis, lib)'));
      expect(transport.getCount, 2);
      await source.load();
      expect(transport.getCount, 2, reason: 'verified modules stay cached');
    });

    test('rejects a module whose SHA-256 does not match', () async {
      final uri = Uri.parse('https://example.test/module.js');
      final source = RemoteEjsModuleSource(
        transport: _FakeTransport(<Uri, InnerTubeHttpResponse>{
          uri: const InnerTubeHttpResponse(statusCode: 200, body: 'tampered'),
        }),
        modules: <EjsModuleSpec>[
          EjsModuleSpec(name: 'core', uri: uri, sha256: '0' * 64),
        ],
      );

      await expectLater(source.load(), throwsA(isA<EjsSolverException>()));
    });

    test('trusts module bytes by hash even after a redirect', () async {
      const body = 'function jsc() {}';
      final uri = Uri.parse('https://example.test/module.js');
      final source = RemoteEjsModuleSource(
        transport: _FakeTransport(<Uri, InnerTubeHttpResponse>{
          uri: InnerTubeHttpResponse(
            statusCode: 200,
            body: body,
            effectiveUri: Uri.parse('https://cdn.example.test/module.js'),
          ),
        }),
        modules: <EjsModuleSpec>[_spec('core', uri.toString(), body)],
      );

      expect(await source.load(), contains(body));
    });
  });

  group('BundledEjsModuleSource', () {
    test('loads and verifies the packaged EJS 0.8.0 release', () async {
      final fallback = _TrackingModuleSource(
        error: StateError('The packaged modules must be self-contained.'),
      );
      final source = BundledEjsModuleSource(fallback: fallback);
      addTearDown(source.close);

      final bundle = await source.load();

      expect(bundle, contains('Object.assign(globalThis, lib);'));
      expect(bundle, contains('var jsc='));
      expect(fallback.calls, 0);
    });

    test('coalesces an asset failure behind the verified fallback', () async {
      const libBody = 'var lib = {};';
      const coreBody = 'function jsc() {}';
      final fallback = _TrackingModuleSource(value: 'verified fallback');
      final source = BundledEjsModuleSource(
        assetLoader: (_) async => base64Encode(utf8.encode('tampered')),
        modules: <EjsModuleSpec>[
          _assetSpec('lib', 'lib.b64', libBody),
          _assetSpec('core', 'core.b64', coreBody),
        ],
        fallback: fallback,
      );
      addTearDown(source.close);

      final values = await Future.wait(<Future<String>>[
        source.load(),
        source.load(),
        source.load(),
      ]);

      expect(values, everyElement('verified fallback'));
      expect(fallback.calls, 1);
    });
  });

  group('EjsSolver', () {
    test(
      'uses packaged modules without requesting GitHub at runtime',
      () async {
        final playerUri = Uri.parse(
          'https://www.youtube.com/s/player/test/base.js',
        );
        final transport = _FakeTransport(<Uri, InnerTubeHttpResponse>{
          playerUri: const InnerTubeHttpResponse(
            statusCode: 200,
            body: 'player source',
          ),
        });
        final runtime = _FakeEjsRuntime();
        final solver = EjsSolver(runtime: runtime, transport: transport);
        addTearDown(solver.dispose);

        expect(
          await solver.solve(playerUri.toString(), EjsChallengeType.n, 'abc'),
          'solved:abc',
        );

        expect(transport.getCount, 1, reason: 'only base.js should be fetched');
        expect(runtime.installCalls, 1);
      },
    );

    test(
      'parses results and caches player, preprocessing and solutions',
      () async {
        final playerUri = Uri.parse(
          'https://www.youtube.com/s/player/test/base.js',
        );
        final transport = _FakeTransport(<Uri, InnerTubeHttpResponse>{
          playerUri: const InnerTubeHttpResponse(
            statusCode: 200,
            body: 'player source',
          ),
        });
        final runtime = _FakeEjsRuntime();
        final solver = EjsSolver(
          runtime: runtime,
          transport: transport,
          moduleSource: _StaticModuleSource(),
        );

        final first = await solver.solveBulk(
          playerUri.toString(),
          <EjsChallengeType, List<String>>{
            EjsChallengeType.n: <String>['abc'],
            EjsChallengeType.sig: <String>['def'],
          },
        );
        final second = await solver.solve(
          playerUri.toString(),
          EjsChallengeType.n,
          'abc',
        );

        expect(first, <String, String?>{
          'abc': 'solved:abc',
          'def': 'solved:def',
        });
        expect(second, 'solved:abc');
        expect(transport.getCount, 1);
        expect(runtime.installCalls, 1);
        expect(runtime.solveCalls, 1);
        await solver.dispose();
        expect(runtime.disposed, isTrue);
      },
    );

    test('coalesces concurrent solves behind the populated cache', () async {
      final playerUri = Uri.parse(
        'https://www.youtube.com/s/player/test/base.js',
      );
      final transport = _FakeTransport(<Uri, InnerTubeHttpResponse>{
        playerUri: const InnerTubeHttpResponse(
          statusCode: 200,
          body: 'player source',
        ),
      });
      final runtime = _FakeEjsRuntime(delay: const Duration(milliseconds: 5));
      final solver = EjsSolver(
        runtime: runtime,
        transport: transport,
        moduleSource: _StaticModuleSource(),
      );

      final values = await Future.wait(<Future<String>>[
        solver.solve(playerUri.toString(), EjsChallengeType.n, 'same'),
        solver.solve(playerUri.toString(), EjsChallengeType.n, 'same'),
        solver.solve(playerUri.toString(), EjsChallengeType.n, 'same'),
      ]);

      expect(values, everyElement('solved:same'));
      expect(transport.getCount, 1);
      expect(runtime.solveCalls, 1);
    });

    test('expires caches using the injected clock', () async {
      final clock = _MutableClock(DateTime.utc(2026));
      final playerUri = Uri.parse(
        'https://www.youtube.com/s/player/test/base.js',
      );
      final transport = _FakeTransport(<Uri, InnerTubeHttpResponse>{
        playerUri: const InnerTubeHttpResponse(
          statusCode: 200,
          body: 'player source',
        ),
      });
      final runtime = _FakeEjsRuntime();
      final solver = EjsSolver(
        runtime: runtime,
        transport: transport,
        moduleSource: _StaticModuleSource(),
        cacheTtl: const Duration(minutes: 5),
        clock: clock.call,
      );

      await solver.solve(playerUri.toString(), EjsChallengeType.n, 'abc');
      clock.value = clock.value.add(const Duration(minutes: 5));
      await solver.solve(playerUri.toString(), EjsChallengeType.n, 'abc');

      expect(transport.getCount, 2);
      expect(runtime.solveCalls, 2);
    });

    test(
      'shares raw player bytes between STS extraction and solving',
      () async {
        final playerUri = Uri.parse(
          'https://www.youtube.com/s/player/test/base.js',
        );
        final transport = _FakeTransport(<Uri, InnerTubeHttpResponse>{
          playerUri: const InnerTubeHttpResponse(
            statusCode: 200,
            body: 'var config={signatureTimestamp:20348};',
          ),
        });
        final solver = EjsSolver(
          runtime: _FakeEjsRuntime(),
          transport: transport,
          moduleSource: _StaticModuleSource(),
        );

        expect(await solver.signatureTimestamp(playerUri.toString()), 20348);
        expect(
          await solver.solve(playerUri.toString(), EjsChallengeType.n, 'abc'),
          'solved:abc',
        );
        expect(transport.getCount, 1);
      },
    );

    test('reinstalls EJS once after its renderer loses global state', () async {
      final playerUri = Uri.parse(
        'https://www.youtube.com/s/player/test/base.js',
      );
      final runtime = _FakeEjsRuntime(failuresBeforeSuccess: 1);
      final solver = EjsSolver(
        runtime: runtime,
        transport: _FakeTransport(<Uri, InnerTubeHttpResponse>{
          playerUri: const InnerTubeHttpResponse(
            statusCode: 200,
            body: 'player source',
          ),
        }),
        moduleSource: _StaticModuleSource(),
      );

      expect(
        await solver.solve(playerUri.toString(), EjsChallengeType.n, 'abc'),
        'solved:abc',
      );
      expect(runtime.installCalls, 2);
      expect(runtime.solveCalls, 2);
    });

    test('rejects and does not cache an unchanged n result', () async {
      final playerUri = Uri.parse(
        'https://www.youtube.com/s/player/test/base.js',
      );
      final runtime = _FakeEjsRuntime(transform: (_, challenge) => challenge);
      final solver = EjsSolver(
        runtime: runtime,
        transport: _FakeTransport(<Uri, InnerTubeHttpResponse>{
          playerUri: const InnerTubeHttpResponse(
            statusCode: 200,
            body: 'player source',
          ),
        }),
        moduleSource: _StaticModuleSource(),
      );

      await expectLater(
        solver.solve(playerUri.toString(), EjsChallengeType.n, 'abc'),
        throwsA(isA<EjsSolverException>()),
      );
      runtime.transform = (_, challenge) => 'fixed:$challenge';

      expect(
        await solver.solve(playerUri.toString(), EjsChallengeType.n, 'abc'),
        'fixed:abc',
      );
      expect(runtime.solveCalls, 2);
    });

    test('rejects an empty EJS result', () async {
      final playerUri = Uri.parse(
        'https://www.youtube.com/s/player/test/base.js',
      );
      final solver = EjsSolver(
        runtime: _FakeEjsRuntime(transform: (_, _) => ''),
        transport: _FakeTransport(<Uri, InnerTubeHttpResponse>{
          playerUri: const InnerTubeHttpResponse(
            statusCode: 200,
            body: 'player source',
          ),
        }),
        moduleSource: _StaticModuleSource(),
      );

      await expectLater(
        solver.solve(playerUri.toString(), EjsChallengeType.sig, 'abc'),
        throwsA(isA<EjsSolverException>()),
      );
    });

    test(
      'rejects untrusted player URLs before network or JavaScript',
      () async {
        final transport = _FakeTransport(const <Uri, InnerTubeHttpResponse>{});
        final runtime = _FakeEjsRuntime();
        final solver = EjsSolver(
          runtime: runtime,
          transport: transport,
          moduleSource: _StaticModuleSource(),
        );

        for (final playerUrl in <String>[
          'http://www.youtube.com/s/player/test/base.js',
          'https://youtube.com.evil.test/s/player/test/base.js',
          'https://www.youtube.com/not-a-player.js',
        ]) {
          await expectLater(
            solver.solve(playerUrl, EjsChallengeType.n, 'abc'),
            throwsA(isA<EjsSolverException>()),
          );
        }

        expect(transport.getCount, 0);
        expect(runtime.installCalls, 0);
        expect(runtime.solveCalls, 0);
      },
    );

    test('does not execute a player redirected outside YouTube', () async {
      final playerUri = Uri.parse(
        'https://www.youtube.com/s/player/test/base.js',
      );
      final transport = _FakeTransport(<Uri, InnerTubeHttpResponse>{
        playerUri: InnerTubeHttpResponse(
          statusCode: 200,
          body: 'player source',
          effectiveUri: Uri.parse('https://evil.test/base.js'),
        ),
      });
      final runtime = _FakeEjsRuntime();
      final solver = EjsSolver(
        runtime: runtime,
        transport: transport,
        moduleSource: _StaticModuleSource(),
      );

      await expectLater(
        solver.solve(playerUri.toString(), EjsChallengeType.n, 'abc'),
        throwsA(isA<EjsSolverException>()),
      );

      expect(transport.getCount, 1);
      expect(runtime.solveCalls, 0);
    });
  });
}

EjsModuleSpec _spec(String name, String uri, String body) => EjsModuleSpec(
  name: name,
  uri: Uri.parse(uri),
  sha256: sha256.convert(utf8.encode(body)).toString(),
);

EjsModuleSpec _assetSpec(String name, String assetPath, String body) =>
    EjsModuleSpec(
      name: name,
      uri: Uri.parse('https://example.test/$name.js'),
      sha256: sha256.convert(utf8.encode(body)).toString(),
      assetPath: assetPath,
    );

class _StaticModuleSource implements EjsModuleSource {
  int calls = 0;

  @override
  Future<String> load() async {
    calls++;
    return 'var lib = {}; function jsc() {}';
  }

  @override
  void close() {}
}

class _TrackingModuleSource implements EjsModuleSource {
  _TrackingModuleSource({this.value = '', this.error});

  final String value;
  final Object? error;
  int calls = 0;
  bool closed = false;

  @override
  Future<String> load() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return value;
  }

  @override
  void close() {
    closed = true;
  }
}

class _FakeEjsRuntime implements YoutubeJavaScriptRuntime {
  _FakeEjsRuntime({this.delay, this.failuresBeforeSuccess = 0, this.transform});

  final Duration? delay;
  int failuresBeforeSuccess;
  String Function(String type, String challenge)? transform;
  int installCalls = 0;
  int solveCalls = 0;
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
    if (functionBody.contains('eval)(ejsModules)')) {
      installCalls++;
      return true;
    }
    solveCalls++;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw const YoutubeJavaScriptRuntimeException('renderer lost');
    }
    if (delay != null) {
      await Future<void>.delayed(delay!);
    }
    final input = Map<String, dynamic>.from(arguments['ejsInput'] as Map);
    final requests = input['requests'] as List;
    return jsonEncode(<String, dynamic>{
      'type': 'result',
      'preprocessed_player': 'preprocessed player',
      'responses': <Map<String, dynamic>>[
        for (final rawRequest in requests)
          <String, dynamic>{
            'type': 'result',
            'data': <String, String>{
              for (final challenge in (rawRequest as Map)['challenges'] as List)
                challenge as String:
                    transform?.call(rawRequest['type'] as String, challenge) ??
                    'solved:$challenge',
            },
          },
      ],
    });
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeTransport implements InnerTubeTransport {
  _FakeTransport(this.responses);

  final Map<Uri, InnerTubeHttpResponse> responses;
  int getCount = 0;

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    getCount++;
    final response = responses[uri];
    if (response == null) {
      throw StateError('Unexpected GET $uri');
    }
    return response;
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

class _MutableClock {
  _MutableClock(this.value);

  DateTime value;

  DateTime call() => value;
}
