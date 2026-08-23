import 'dart:convert';

import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_header_factory.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_cookie_codec.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_navigation_policy.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_sid_auth_signer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('YouTubeMusicCookieCodec', () {
    const codec = YouTubeMusicCookieCodec();

    test('parses the first equals sign and emits a stable canonical order', () {
      final decoded = codec.decode(
        ' VISITOR_INFO1_LIVE=visitor=value ; SAPISID=test-session-value ',
      );

      expect(decoded['VISITOR_INFO1_LIVE'], 'visitor=value');
      expect(
        codec.encode(decoded),
        'SAPISID=test-session-value; VISITOR_INFO1_LIVE=visitor=value',
      );
    });

    test('accepts each supported signing-cookie variant', () {
      for (final name in const <String>[
        'SAPISID',
        '__Secure-1PAPISID',
        '__Secure-3PAPISID',
      ]) {
        expect(codec.decode('$name=test-value'), contains(name));
      }
    });

    test('rejects duplicates, controls, malformed and unsigned cookies', () {
      for (final value in <String>[
        'SAPISID=one; SAPISID=two',
        'SAPISID=test\r\nInjected=value',
        'SAPISID',
        'VISITOR_INFO1_LIVE=test-only',
      ]) {
        expect(() => codec.decode(value), throwsFormatException, reason: value);
      }
    });

    test('enforces byte and count limits when decoding and encoding', () {
      const tiny = YouTubeMusicCookieCodec(maximumBytes: 30, maximumCookies: 1);
      expect(
        () => tiny.decode('SAPISID=test; another=value'),
        throwsFormatException,
      );
      expect(
        () => tiny.encode(const <String, String>{
          'SAPISID': 'a-test-value-that-is-far-too-large',
        }),
        throwsFormatException,
      );
    });
  });

  group('YouTubeMusicNavigationPolicy', () {
    const policy = YouTubeMusicNavigationPolicy();

    test('allows only exact whitelisted HTTPS main-frame hosts', () {
      for (final host in YouTubeMusicNavigationPolicy.defaultAllowedHosts) {
        expect(
          policy.evaluate(Uri.parse('https://$host/path'), isMainFrame: true),
          YouTubeMusicNavigationDecision.allow,
        );
      }
    });

    test('blocks lookalikes, credentials, custom ports and schemes', () {
      for (final value in const <String>[
        'https://accounts.google.com.evil.example/',
        'https://evil.example@music.youtube.com/',
        'https://music.youtube.com:444/',
        'http://music.youtube.com/',
        'javascript:alert(1)',
        'intent://music.youtube.com/',
      ]) {
        expect(
          policy.evaluate(Uri.parse(value), isMainFrame: true),
          YouTubeMusicNavigationDecision.cancel,
          reason: value,
        );
      }
      expect(
        policy.evaluate(null, isMainFrame: true),
        YouTubeMusicNavigationDecision.cancel,
      );
      expect(
        policy.evaluate(
          Uri.parse('https://accounts.google.com.evil.example/'),
          isMainFrame: true,
        ),
        YouTubeMusicNavigationDecision.cancel,
      );
      expect(
        policy.evaluate(
          Uri.parse('https://accounts.google.com/'),
          isMainFrame: true,
        ),
        YouTubeMusicNavigationDecision.allow,
      );
      expect(
        policy.evaluate(
          Uri.parse('https://accounts-login.google.com/'),
          isMainFrame: true,
        ),
        YouTubeMusicNavigationDecision.allow,
      );
      expect(
        policy.evaluate(
          Uri.parse('https://accounts.google.com./'),
          isMainFrame: true,
        ),
        YouTubeMusicNavigationDecision.allow,
      );
      expect(
        policy.evaluate(
          Uri.parse('https://accounts.google.com.ni/accounts/SetSID'),
          isMainFrame: true,
        ),
        YouTubeMusicNavigationDecision.allow,
      );
      expect(
        policy.evaluate(
          Uri.parse('https://accounts.google.com.evil/'),
          isMainFrame: true,
        ),
        YouTubeMusicNavigationDecision.cancel,
      );
      expect(
        policy.evaluate(Uri.parse('about:blank'), isMainFrame: true),
        YouTubeMusicNavigationDecision.allow,
      );
    });

    test('recovers only the exact Google hand-off intents', () {
      expect(
        policy.safeIntentDestination(
          'intent://play.google.com/store/apps/details?id=com.google.android.apps.music'
          '#Intent;scheme=https;end',
        ),
        Uri.parse(
          'https://play.google.com/store/apps/details?id=com.google.android.apps.music',
        ),
      );
      expect(
        policy.safeIntentDestination(
          'intent://accounts.youtube.com/accounts/SetSID?continue=https%3A%2F%2Fmusic.youtube.com%2F'
          '#Intent;scheme=https;end',
        ),
        Uri.parse(
          'https://accounts.youtube.com/accounts/SetSID?continue=https%3A%2F%2Fmusic.youtube.com%2F',
        ),
      );
      expect(
        policy.safeIntentDestination(
          'intent://evil.example/#Intent;scheme=https;end',
        ),
        isNull,
      );
      expect(policy.safeIntentDestination('https://play.google.com/'), isNull);
      expect(
        policy.isSafeAuthContinuation(Uri.parse('https://play.google.com/')),
        isTrue,
      );
      expect(
        policy.isSafeAuthContinuation(
          Uri.parse('https://passwords.google.com/'),
        ),
        isTrue,
      );
    });

    test('allows HTTPS CDN subframes without weakening the main frame', () {
      expect(
        policy.evaluate(
          Uri.parse('https://accounts-cdn.example/resource'),
          isMainFrame: false,
        ),
        YouTubeMusicNavigationDecision.allow,
      );
      expect(
        policy.evaluate(
          Uri.parse('http://accounts-cdn.example/resource'),
          isMainFrame: false,
        ),
        YouTubeMusicNavigationDecision.cancel,
      );
    });

    test('recognizes only the exact YouTube Music HTTPS document', () {
      expect(
        policy.isYouTubeMusicDocument(
          Uri.parse('https://music.youtube.com:443/watch'),
        ),
        isTrue,
      );
      expect(
        policy.isYouTubeMusicDocument(
          Uri.parse('https://music.youtube.com.evil.example/'),
        ),
        isFalse,
      );
      expect(
        policy.isYouTubeMusicDocument(
          Uri.parse('https://user@music.youtube.com/'),
        ),
        isFalse,
      );
    });

    test('recognizes the exact YouTube hand-off documents', () {
      expect(
        policy.isYouTubeAuthDocument(
          Uri.parse('https://www.youtube.com/watch?v=abc'),
        ),
        isTrue,
      );
      expect(
        policy.isYouTubeAuthDocument(Uri.parse('https://youtube.com/')),
        isTrue,
      );
      expect(
        policy.isYouTubeAuthDocument(
          Uri.parse('https://www.youtube.com.evil.example/'),
        ),
        isFalse,
      );
      expect(
        policy.isYouTubeAuthDocument(Uri.parse('http://www.youtube.com/')),
        isFalse,
      );
    });
  });

  group('YouTubeMusicSidAuthSigner', () {
    final instant = DateTime.fromMillisecondsSinceEpoch(
      1700000000000,
      isUtc: true,
    );

    test('matches a fixed SAPISIDHASH protocol vector', () {
      final signer = YouTubeMusicSidAuthSigner(clock: () => instant);
      expect(
        signer.sign('SAPISID=test-sapisid-value'),
        'SAPISIDHASH '
        '1700000000_0c0d2e2ebe5f3603ce622ae1dceaa2917419aeb8',
      );
    });

    test('emits the three proofs when all signing cookies exist', () {
      final signer = YouTubeMusicSidAuthSigner(clock: () => instant);
      expect(
        signer.sign(
          'SAPISID=test-sapisid-value; '
          '__Secure-1PAPISID=test-1p-value; '
          '__Secure-3PAPISID=test-3p-value',
        ),
        'SAPISIDHASH '
        '1700000000_0c0d2e2ebe5f3603ce622ae1dceaa2917419aeb8 '
        'SAPISID1PHASH '
        '1700000000_5c18314e2ea33f396ea1cc3d9114d528bac019d9 '
        'SAPISID3PHASH '
        '1700000000_68825f7dd8c4652f219025f1603936a070700847',
      );
    });

    test('uses 3PAPISID as the compatible primary fallback', () {
      final signer = YouTubeMusicSidAuthSigner(clock: () => instant);
      final result = signer.sign('__Secure-3PAPISID=test-3p-value');
      expect(result, startsWith('SAPISIDHASH '));
      expect(result, contains(' SAPISID3PHASH '));
    });
  });

  group('models and exact-host headers', () {
    test('credential round-trips while string output remains redacted', () {
      final credential = _credential();
      final restored = YouTubeMusicSessionCredential.decode(
        credential.encode(),
      );

      expect(restored.cookieHeader, credential.cookieHeader);
      expect(restored.identity.visitorData, 'test-visitor-data');
      expect(restored.apiKey, 'test_api_key');
      expect(restored.clientVersion, '1.20260822.00.00');
      expect(restored.clientName, 'WEB_REMIX');
      expect(restored.region, 'MX');
      expect(restored.profile.displayName, 'Cuenta de prueba');
      expect(restored.validatedAt, credential.validatedAt);
      for (final output in <String>[
        credential.toString(),
        credential.identity.toString(),
        YouTubeMusicWebAuthData(
          cookieHeader: credential.cookieHeader,
          identity: credential.identity,
          apiKey: credential.apiKey,
          clientVersion: credential.clientVersion,
          clientName: credential.clientName,
        ).toString(),
      ]) {
        expect(output, isNot(contains('test-session-value')));
        expect(output, isNot(contains('test-visitor-data')));
        expect(output, isNot(contains('test_api_key')));
      }
    });

    test('rejects malformed or unbounded bootstrap configuration', () {
      for (final values in <({String apiKey, String version, String name})>[
        (apiKey: 'bad key', version: '1.test', name: 'WEB_REMIX'),
        (apiKey: 'test_key', version: 'bad version', name: 'WEB_REMIX'),
        (apiKey: 'test_key', version: '1.test', name: 'WEB REMIX'),
        (apiKey: 'x' * 513, version: '1.test', name: 'WEB_REMIX'),
      ]) {
        expect(
          () => YouTubeMusicWebAuthData(
            cookieHeader: 'SAPISID=test-session-value',
            identity: const YouTubeMusicAuthIdentity(
              visitorData: 'test-visitor-data',
              authUser: '0',
            ),
            apiKey: values.apiKey,
            clientVersion: values.version,
            clientName: values.name,
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects future, malformed and oversized credential documents', () {
      final futureDocument = jsonEncode(<String, Object?>{
        'version': YouTubeMusicSessionCredential.schemaVersion + 1,
      });
      expect(
        () => YouTubeMusicSessionCredential.decode(futureDocument),
        throwsFormatException,
      );
      expect(
        () => YouTubeMusicSessionCredential.decode('{invalid'),
        throwsFormatException,
      );
      expect(
        () => YouTubeMusicSessionCredential.decode(
          'x' * (YouTubeMusicSessionCredential.maximumEncodedBytes + 1),
        ),
        throwsFormatException,
      );
    });

    test('validates session index and HTTPS avatar input', () {
      expect(
        () => YouTubeMusicAuthIdentity.fromJson(<String, Object?>{
          'visitorData': 'visitor',
          'authUser': '-1',
        }),
        throwsFormatException,
      );
      expect(
        () => YouTubeMusicAccountProfile.fromJson(<String, Object?>{
          'channelId': 'channel',
          'displayName': 'Account',
          'avatarUrl': 'http://example.test/avatar.png',
        }),
        throwsFormatException,
      );
    });

    test('creates complete headers only for the exact music origin', () {
      final factory = YouTubeMusicAuthHeaderFactory(
        signer: YouTubeMusicSidAuthSigner(
          clock: () =>
              DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
        ),
      );
      final credential = _credential();
      final headers = factory.create(
        Uri.parse('https://music.youtube.com/youtubei/v1/browse'),
        credential,
      );

      expect(headers['Cookie'], 'SAPISID=test-session-value');
      expect(headers['Authorization'], startsWith('SAPISIDHASH 1700000000_'));
      expect(headers['Origin'], 'https://music.youtube.com');
      expect(headers['X-Goog-AuthUser'], '0');
      expect(headers['X-Goog-Visitor-Id'], 'test-visitor-data');
      expect(headers['X-Goog-PageId'], 'test-page-id');
      expect(() => headers['Injected'] = 'value', throwsUnsupportedError);
    });

    test('never adds credentials to lookalike or non-origin requests', () {
      final factory = YouTubeMusicAuthHeaderFactory();
      for (final value in const <String>[
        'https://music.youtube.com.evil.example/path',
        'https://user@music.youtube.com/path',
        'https://music.youtube.com:444/path',
        'http://music.youtube.com/path',
        'https://googlevideo.com/path',
      ]) {
        expect(factory.create(Uri.parse(value), _credential()), isEmpty);
      }
    });
  });
}

YouTubeMusicSessionCredential _credential() => YouTubeMusicSessionCredential(
  cookieHeader: 'SAPISID=test-session-value',
  identity: const YouTubeMusicAuthIdentity(
    visitorData: 'test-visitor-data',
    authUser: '0',
    dataSyncId: 'test-data-sync',
    delegatedPageId: 'test-page-id',
  ),
  profile: YouTubeMusicAccountProfile(
    channelId: 'test-channel-id',
    displayName: 'Cuenta de prueba',
    avatarUrl: Uri.parse('https://yt3.googleusercontent.com/test-avatar'),
  ),
  validatedAt: DateTime.utc(2026, 8, 22, 12),
  apiKey: 'test_api_key',
  clientVersion: '1.20260822.00.00',
  clientName: 'WEB_REMIX',
  region: 'mx',
);
