import 'dart:async';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/youtube_music/playback/headless_inappwebview_runtime.dart';
import 'package:bstream_music/services/youtube_music/playback/javascript_runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('headless document hardening', () {
    test('injects the restrictive CSP before every script exactly once', () {
      const source =
          '<!doctype html><html><head><title>x</title>'
          '<script>window.value = 1;</script></head></html>';

      final hardened = hardenYoutubeJavaScriptDocument(source);

      expect(
        hardened.indexOf('data-bstream-runtime-csp'),
        lessThan(hardened.indexOf('<script>')),
      );
      expect(hardened, contains("default-src 'none'"));
      expect(hardened, contains("script-src 'unsafe-inline' 'unsafe-eval'"));
      expect(hardened, contains("connect-src 'none'"));
      expect(hardened, contains("worker-src 'none'"));
      expect(hardened, contains("frame-src 'none'"));
      expect(hardened, contains("navigate-to 'none'"));
      expect('data-bstream-runtime-csp'.allMatches(hardened), hasLength(1));
      expect(hardenYoutubeJavaScriptDocument(hardened), hardened);
    });

    test('rejects an existing runtime CSP placed after a script', () {
      expect(
        () => hardenYoutubeJavaScriptDocument(
          '<html><head><script></script>$youtubeJavaScriptRuntimeCspMeta'
          '</head></html>',
        ),
        throwsA(isA<YoutubeJavaScriptRuntimeException>()),
      );
    });

    test('rejects a marker that does not carry the exact runtime policy', () {
      expect(
        () => hardenYoutubeJavaScriptDocument(
          '<html><head><meta data-bstream-runtime-csp="true" '
          'http-equiv="Content-Security-Policy" content="default-src *">'
          '</head></html>',
        ),
        throwsA(isA<YoutubeJavaScriptRuntimeException>()),
      );
    });

    test(
      'checked-in BotGuard harness places the CSP before its script',
      () async {
        final html = await rootBundle.loadString(
          'assets/youtube/po_token.html',
        );

        expect(
          html.indexOf('data-bstream-runtime-csp'),
          inInclusiveRange(0, html.indexOf('<script>') - 1),
        );
        expect(html, contains(youtubeJavaScriptRuntimeCsp));
        expect(hardenYoutubeJavaScriptDocument(html), html);
      },
    );
  });

  group('HeadlessInAppWebViewJavaScriptRuntime lifecycle', () {
    test('denies every document-initiated navigation', () {
      expect(
        HeadlessInAppWebViewJavaScriptRuntime.allowsNavigation(
          Uri.parse('https://www.youtube.com/'),
        ),
        isFalse,
      );
      expect(
        HeadlessInAppWebViewJavaScriptRuntime.allowsNavigation(
          Uri.parse('about:blank'),
        ),
        isFalse,
      );
      expect(
        HeadlessInAppWebViewJavaScriptRuntime.allowsNavigation(null),
        isFalse,
      );
    });

    test(
      'retires a timed-out renderer and recreates the hardened harness',
      () async {
        final backends = <_FakeHeadlessBackend>[];
        final stalled = Completer<CallAsyncJavaScriptResult?>();
        var backendIndex = 0;
        final runtime = HeadlessInAppWebViewJavaScriptRuntime(
          platform: AppPlatformType.windows,
          executionTimeout: const Duration(milliseconds: 20),
          backendFactory: () {
            final backend = _FakeHeadlessBackend(
              execute: backendIndex++ == 0
                  ? (_, _) => stalled.future
                  : (_, _) async => CallAsyncJavaScriptResult(value: 'fresh'),
            );
            backends.add(backend);
            return backend;
          },
        );
        const harness =
            '<!doctype html><html><head><script>window.ready=true;</script>'
            '</head></html>';
        final origin = Uri.parse('https://www.youtube.com/');

        await runtime.initialize(html: harness, baseUrl: origin);
        await expectLater(
          runtime.callAsyncJavaScript(functionBody: 'return 1;'),
          throwsA(
            isA<YoutubeJavaScriptRuntimeException>().having(
              (error) => error.message,
              'message',
              contains('timed out'),
            ),
          ),
        );

        expect(backends, hasLength(1));
        expect(backends.first.disposed, isTrue);
        expect(
          await runtime.callAsyncJavaScript(functionBody: 'return 2;'),
          'fresh',
        );
        expect(backends, hasLength(2));
        expect(backends.last.html, backends.first.html);
        expect(backends.last.baseUrl, origin);
        expect(
          backends.last.html.indexOf('data-bstream-runtime-csp'),
          lessThan(backends.last.html.indexOf('<script>')),
        );

        await runtime.dispose();
        expect(backends.last.disposed, isTrue);
      },
    );

    test(
      'renderer termination invalidates the controller before recreation',
      () async {
        final backends = <_FakeHeadlessBackend>[];
        final runtime = HeadlessInAppWebViewJavaScriptRuntime(
          platform: AppPlatformType.android,
          backendFactory: () {
            final backend = _FakeHeadlessBackend(
              execute: (_, _) async => CallAsyncJavaScriptResult(value: 7),
            );
            backends.add(backend);
            return backend;
          },
        );

        await runtime.initialize();
        backends.single.invalidateRenderer(StateError('renderer gone'));

        expect(await runtime.callAsyncJavaScript(functionBody: 'return 7;'), 7);
        expect(backends, hasLength(2));
        expect(backends.first.disposed, isTrue);

        await runtime.dispose();
      },
    );

    test('a JavaScript exception keeps a healthy renderer available', () async {
      final backend = _FakeHeadlessBackend(
        execute: (_, _) async => CallAsyncJavaScriptResult(error: 'boom'),
      );
      final runtime = HeadlessInAppWebViewJavaScriptRuntime(
        platform: AppPlatformType.macos,
        backendFactory: () => backend,
      );

      await expectLater(
        runtime.callAsyncJavaScript(functionBody: 'throw new Error();'),
        throwsA(isA<YoutubeJavaScriptRuntimeException>()),
      );

      expect(backend.disposed, isFalse);
      expect(backend.initializeCalls, 1);
      await runtime.dispose();
    });
  });
}

typedef _Execute =
    Future<CallAsyncJavaScriptResult?> Function(
      String functionBody,
      Map<String, dynamic> arguments,
    );

class _FakeHeadlessBackend implements HeadlessJavaScriptRuntimeBackend {
  _FakeHeadlessBackend({required this.execute});

  final _Execute execute;

  late String html;
  late Uri baseUrl;
  late void Function(Object cause) _onRendererInvalidated;
  int initializeCalls = 0;
  bool disposed = false;

  @override
  Future<void> initialize({
    required String html,
    required Uri baseUrl,
    required AppPlatformType platform,
    required String userAgent,
    required void Function(Object cause) onRendererInvalidated,
  }) async {
    initializeCalls++;
    this.html = html;
    this.baseUrl = baseUrl;
    _onRendererInvalidated = onRendererInvalidated;
  }

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    required Map<String, dynamic> arguments,
  }) => execute(functionBody, arguments);

  void invalidateRenderer(Object cause) => _onRendererInvalidated(cause);

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
