import 'package:bstream_music/features/music/presentation/pages/youtube_music_login_page.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/services/youtube_music/auth/inappwebview_youtube_music_web_auth_port.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_account_client.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_web_auth_port.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('failed private-session preparation can be retried', (
    tester,
  ) async {
    var prepareAttempts = 0;
    final port = _ControlledPreparePort(
      onPrepare: () async {
        prepareAttempts += 1;
        throw YouTubeMusicWebAuthException('prepare-$prepareAttempts');
      },
    );

    await tester.pumpWidget(_testApp(port, includeLoginRoute: false));
    await tester.pumpAndSettle();

    expect(prepareAttempts, 1);
    expect(find.text('prepare-1'), findsOneWidget);
    await tester.tap(find.text('Reintentar preparación'));
    await tester.pumpAndSettle();

    expect(prepareAttempts, 2);
    expect(find.text('prepare-2'), findsOneWidget);
  });

  testWidgets('login page stays open until WebView cleanup is verified', (
    tester,
  ) async {
    var storagePasses = 0;
    final port = _PrepareFailingPort(
      authenticationCookieCleaner: () async => true,
      webStorageCleaner: () async {
        storagePasses += 1;
        if (storagePasses == 1) throw StateError('transient cleanup failure');
      },
      cacheCleaner: () async {},
    );

    await tester.pumpWidget(_testApp(port, includeLoginRoute: true));
    await tester.pumpAndSettle();

    expect(find.text('preparation blocked for test'), findsOneWidget);
    await tester.tap(find.byKey(const Key('youtube-music-login-close')));
    await tester.pumpAndSettle();

    expect(storagePasses, 1);
    expect(find.text('Reintentar limpieza y cerrar'), findsOneWidget);
    expect(find.text('home-marker'), findsNothing);

    await tester.tap(find.text('Reintentar limpieza y cerrar'));
    await tester.pumpAndSettle();

    expect(storagePasses, 2);
    expect(find.text('home-marker'), findsOneWidget);
  });
}

Widget _testApp(
  InAppWebViewYouTubeMusicWebAuthPort port, {
  required bool includeLoginRoute,
}) {
  final login = YouTubeMusicLoginPage(webAuthPort: port);
  return ProviderScope(
    overrides: [
      youtubeMusicSessionStoreProvider.overrideWithValue(_MemorySessionStore()),
      youtubeMusicAccountClientProvider.overrideWithValue(
        const UnconfiguredYouTubeMusicAccountClient(),
      ),
    ],
    child: includeLoginRoute
        ? MaterialApp(
            initialRoute: '/login',
            routes: <String, WidgetBuilder>{
              '/': (_) => const Scaffold(body: Text('home-marker')),
              '/login': (_) => login,
            },
          )
        : MaterialApp(home: login),
  );
}

class _ControlledPreparePort extends InAppWebViewYouTubeMusicWebAuthPort {
  _ControlledPreparePort({required this.onPrepare})
    : super(
        authenticationCookieCleaner: _trueCleanup,
        webStorageCleaner: _voidCleanup,
        cacheCleaner: _voidCleanup,
      );

  final Future<void> Function() onPrepare;

  @override
  Future<void> prepare() => onPrepare();
}

Future<bool> _trueCleanup() async => true;

Future<void> _voidCleanup() async {}

class _PrepareFailingPort extends InAppWebViewYouTubeMusicWebAuthPort {
  _PrepareFailingPort({
    required super.authenticationCookieCleaner,
    required super.webStorageCleaner,
    required super.cacheCleaner,
  });

  @override
  Future<void> prepare() async {
    throw const YouTubeMusicWebAuthException('preparation blocked for test');
  }
}

class _MemorySessionStore implements YouTubeMusicSessionStore {
  @override
  Future<void> delete() async {}

  @override
  Future<YouTubeMusicSessionCredential?> read() async => null;

  @override
  Future<void> write(YouTubeMusicSessionCredential credential) async {}
}
