import 'dart:async';

import 'package:bstream_music/services/youtube_music/auth/inappwebview_youtube_music_web_auth_port.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_web_auth_port.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'prepare fails closed when any private browser store is not cleared',
    () async {
      for (final failedStore in const <String>[
        'cookies',
        'web-storage',
        'cache',
      ]) {
        var cookieCalls = 0;
        var storageCalls = 0;
        var cacheCalls = 0;
        final port = InAppWebViewYouTubeMusicWebAuthPort(
          authenticationCookieCleaner: () async {
            cookieCalls += 1;
            return failedStore != 'cookies';
          },
          webStorageCleaner: () async {
            storageCalls += 1;
            if (failedStore == 'web-storage') {
              throw StateError('storage unavailable');
            }
          },
          cacheCleaner: () async {
            cacheCalls += 1;
            if (failedStore == 'cache') {
              throw StateError('cache unavailable');
            }
          },
        );

        if (failedStore == 'cookies') {
          await expectLater(
            port.prepare(),
            throwsA(isA<YouTubeMusicWebAuthException>()),
            reason: failedStore,
          );
        } else {
          // Cache/DOM storage are best-effort platform stores. A failed
          // cleanup there must not block a fresh authenticated session when
          // the cookie boundary was cleared successfully.
          await port.prepare();
        }
        expect(cookieCalls, 1, reason: failedStore);
        expect(storageCalls, 1, reason: failedStore);
        expect(cacheCalls, 1, reason: failedStore);
      }
    },
  );

  test(
    'a noncritical cleanup failure does not block a fresh session',
    () async {
      var cookieCalls = 0;
      var storageCalls = 0;
      var cacheCalls = 0;
      final port = InAppWebViewYouTubeMusicWebAuthPort(
        authenticationCookieCleaner: () async {
          cookieCalls += 1;
          return true;
        },
        webStorageCleaner: () async {
          storageCalls += 1;
          if (storageCalls == 1) throw StateError('transient failure');
        },
        cacheCleaner: () async => cacheCalls += 1,
      );

      await port.prepare();
      await port.prepare();

      expect(cookieCalls, 2);
      expect(storageCalls, 2);
      expect(cacheCalls, 2);
    },
  );

  test('partial cleanup is reported and every store is retried', () async {
    var cookieCalls = 0;
    var storageCalls = 0;
    var cacheCalls = 0;
    final port = InAppWebViewYouTubeMusicWebAuthPort(
      authenticationCookieCleaner: () async {
        cookieCalls += 1;
        return true;
      },
      webStorageCleaner: () async {
        storageCalls += 1;
        if (storageCalls == 1) throw StateError('transient failure');
      },
      cacheCleaner: () async => cacheCalls += 1,
    );

    final first = await port.cleanup();
    expect(first.cookiesCleared, isTrue);
    expect(first.webStorageCleared, isFalse);
    expect(first.cacheCleared, isTrue);
    expect(first.completed, isFalse);

    final second = await port.cleanup();
    expect(second.completed, isTrue);
    expect(cookieCalls, 2);
    expect(storageCalls, 2);
    expect(cacheCalls, 2);

    final alreadyClean = await port.cleanup();
    expect(alreadyClean.completed, isTrue);
    expect(cookieCalls, 2);
    expect(storageCalls, 2);
    expect(cacheCalls, 2);
  });

  test(
    'cleanup closes navigation immediately while its result is pending',
    () async {
      final cookies = Completer<bool>();
      final port = InAppWebViewYouTubeMusicWebAuthPort(
        authenticationCookieCleaner: () => cookies.future,
        webStorageCleaner: () async {},
        cacheCleaner: () async {},
      );

      final cleanup = port.cleanup();
      await expectLater(
        port.navigate(Uri.parse('https://music.youtube.com/')),
        throwsStateError,
      );

      cookies.complete(true);
      expect((await cleanup).completed, isTrue);
    },
  );
}
