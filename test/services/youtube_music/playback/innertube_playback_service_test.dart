import 'dart:async';
import 'dart:convert';

import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:bstream_music/services/youtube_music/playback/ejs_solver.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_profile.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_router.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_playback_service.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_player_bootstrap.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_models.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_validator.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_binding.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const videoId = 'dQw4w9WgXcQ';

  test('resolves and validates VisionOS audio', () async {
    final transport = _FakeTransport((headers, request) {
      expect(headers['Referer'], 'https://music.youtube.com/');
      expect(headers['X-Origin'], 'https://music.youtube.com');
      expect(headers['Accept-Language'], 'en-US,en;q=0.9');
      expect(request['videoId'], videoId);
      return _playerResponse(
        videoId: videoId,
        url: 'https://media.example/audio?expire=2000000000',
      );
    });
    final validator = _FakeValidator();
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: validator,
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.visionOS],
        primaryKey: 'visionOS',
      ),
      maxRequestAttempts: 1,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1900000000000),
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.profile.key, 'visionOS');
    expect(result.format.itag, 140);
    expect(result.extension, 'm4a');
    expect(result.codec, 'mp4a.40.2');
    expect(validator.uris, [result.uri]);
    expect(transport.postCount, 1);
  });

  test('resolves the highest-bitrate compatible audio format', () async {
    final transport = _FakeTransport((_, _) {
      final response = _playerResponse(
        videoId: videoId,
        url: 'https://media.example/aac',
      );
      final adaptive =
          (response['streamingData'] as Map<String, dynamic>)['adaptiveFormats']
              as List<Map<String, dynamic>>;
      adaptive.add(<String, dynamic>{
        'itag': 251,
        'mimeType': 'audio/webm; codecs="opus"',
        'bitrate': 192000,
        'contentLength': '2500000',
        'url': 'https://media.example/opus',
      });
      return response;
    });
    final validator = _FakeValidator();
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: validator,
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.visionOS],
        primaryKey: 'visionOS',
      ),
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.format.itag, 251);
    expect(result.extension, 'webm');
    expect(validator.uris, [Uri.parse('https://media.example/opus')]);
  });

  test('AVFoundation policy selects AAC when WebM is also available', () async {
    final transport = _FakeTransport((_, _) {
      final response = _playerResponse(
        videoId: videoId,
        url: 'https://media.example/aac',
      );
      final adaptive =
          (response['streamingData'] as Map<String, dynamic>)['adaptiveFormats']
              as List<Map<String, dynamic>>;
      adaptive.insert(0, <String, dynamic>{
        'itag': 251,
        'mimeType': 'audio/webm; codecs="opus"',
        'bitrate': 192000,
        'contentLength': '2500000',
        'url': 'https://media.example/opus',
      });
      return response;
    });
    final validator = _FakeValidator();
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: validator,
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.visionOS],
        primaryKey: 'visionOS',
      ),
      audioFormatPredicate: isAvFoundationCompatibleInnerTubeAudio,
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.format.itag, 140);
    expect(result.extension, 'm4a');
    expect(validator.uris, [Uri.parse('https://media.example/aac')]);
  });

  test(
    'AVFoundation policy skips a WebM-only client for an AAC fallback',
    () async {
      final primary = _profile(
        key: 'webm-primary',
        clientName: 'WEBM_PRIMARY',
        clientId: 3,
      );
      final secondary = _profile(
        key: 'aac-secondary',
        clientName: 'AAC_SECONDARY',
        clientId: 7,
      );
      final router = InnerTubeClientRouter(
        profiles: [primary, secondary],
        primaryKey: primary.key,
        failuresBeforeCooldown: 1,
      );
      final transport = _FakeTransport((headers, _) {
        final webmOnly = headers['X-YouTube-Client-Name'] == '3';
        final response = _playerResponse(
          videoId: videoId,
          url: webmOnly
              ? 'https://media.example/opus'
              : 'https://media.example/aac',
        );
        if (webmOnly) {
          final format =
              (((response['streamingData']
                            as Map<String, dynamic>)['adaptiveFormats']
                        as List<Map<String, dynamic>>)
                    .single)
                ..['itag'] = 251
                ..['mimeType'] = 'audio/webm; codecs="opus"';
          expect(format['url'], 'https://media.example/opus');
        }
        return response;
      });
      final validator = _FakeValidator();
      final service = InnerTubePlaybackService(
        transport: transport,
        validator: validator,
        router: router,
        audioFormatPredicate: isAvFoundationCompatibleInnerTubeAudio,
        maxRequestAttempts: 1,
      );
      addTearDown(service.dispose);

      final result = await service.resolve(videoId);

      expect(result.profile.key, secondary.key);
      expect(result.format.itag, 140);
      expect(transport.postCount, 2);
      expect(validator.uris, [Uri.parse('https://media.example/aac')]);
      expect(router.healthFor(primary.key).consecutiveFailures, 0);
    },
  );

  test(
    'AVFoundation policy reports a clear error for only WebM audio',
    () async {
      final router = InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.visionOS],
        primaryKey: 'visionOS',
        failuresBeforeCooldown: 1,
      );
      final transport = _FakeTransport((_, _) {
        final response = _playerResponse(
          videoId: videoId,
          url: 'https://media.example/opus',
        );
        (((response['streamingData'] as Map<String, dynamic>)['adaptiveFormats']
                  as List<Map<String, dynamic>>)
              .single)
          ..['itag'] = 251
          ..['mimeType'] = 'audio/webm; codecs="opus"';
        return response;
      });
      final validator = _FakeValidator();
      final service = InnerTubePlaybackService(
        transport: transport,
        validator: validator,
        router: router,
        audioFormatPredicate: isAvFoundationCompatibleInnerTubeAudio,
        maxRequestAttempts: 1,
      );
      addTearDown(service.dispose);

      await expectLater(
        service.resolve(videoId),
        throwsA(
          isA<InnerTubePlaybackException>().having(
            (error) => error.failures.single.error.toString(),
            'platform format error',
            contains('no audio format supported by this platform'),
          ),
        ),
      );

      expect(validator.uris, isEmpty);
      expect(router.healthFor('visionOS').consecutiveFailures, 0);
    },
  );

  test('falls back after a mismatched player response', () async {
    final secondary = _profile(
      key: 'secondary',
      clientName: 'TVHTML5',
      clientId: 7,
    );
    final transport = _FakeTransport((headers, _) {
      final clientId = headers['X-YouTube-Client-Name'];
      return _playerResponse(
        videoId: clientId == '101' ? 'aaaaaaaaaaa' : videoId,
        url: 'https://media.example/$clientId',
      );
    });
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: InnerTubeClientRouter(
        profiles: [InnerTubeClientRegistry.visionOS, secondary],
        primaryKey: 'visionOS',
      ),
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.profile.key, 'secondary');
    expect(transport.postCount, 2);
  });

  test('content-specific failures do not cool down healthy clients', () async {
    final router = InnerTubeClientRouter(
      profiles: const [InnerTubeClientRegistry.visionOS],
      primaryKey: 'visionOS',
      failuresBeforeCooldown: 1,
    );
    final transport = _FakeTransport((_, request) {
      final response = _playerResponse(
        videoId: request['videoId']! as String,
        url: 'https://media.example/audio',
      );
      response['playabilityStatus'] = <String, dynamic>{
        'status': 'LOGIN_REQUIRED',
        'reason': 'This video is private.',
      };
      return response;
    });
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: router,
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.resolve(videoId),
      throwsA(isA<InnerTubePlaybackException>()),
    );

    final health = router.healthFor('visionOS');
    expect(health.consecutiveFailures, 0);
    expect(health.cooldownUntil, isNull);
    expect(health.lastFailure, isNull);
  });

  test('a timed-out resolve cannot mutate client health afterward', () async {
    final responseGate = Completer<void>();
    final router = InnerTubeClientRouter(
      profiles: const [InnerTubeClientRegistry.visionOS],
      primaryKey: 'visionOS',
      failuresBeforeCooldown: 1,
    );
    final transport = _FakeTransport((_, request) async {
      await responseGate.future;
      return _playerResponse(
        videoId: request['videoId']! as String,
        url: 'https://media.example/audio',
      );
    });
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: router,
      maxRequestAttempts: 1,
      resolveTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.resolve(videoId),
      throwsA(isA<TimeoutException>()),
    );
    responseGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final health = router.healthFor('visionOS');
    expect(health.successes, 0);
    expect(health.consecutiveFailures, 0);
    expect(health.cooldownUntil, isNull);
  });

  test(
    'audio-only mode skips a client that exposes only a muxed format',
    () async {
      final transport = _FakeTransport((headers, _) {
        if (headers['X-YouTube-Client-Name'] == '3') {
          final response = _playerResponse(
            videoId: videoId,
            url: 'https://media.example/muxed',
          );
          final streaming = response['streamingData'] as Map<String, dynamic>;
          final adaptive = streaming.remove('adaptiveFormats');
          final muxed = Map<String, dynamic>.from(
            (adaptive as List).single as Map,
          )..['mimeType'] = 'video/mp4; codecs="avc1.42001E, mp4a.40.2"';
          streaming['formats'] = <Object?>[muxed];
          return response;
        }
        return _playerResponse(
          videoId: videoId,
          url: 'https://media.example/audio-only',
        );
      });
      final service = InnerTubePlaybackService(
        transport: transport,
        validator: _FakeValidator(),
        router: InnerTubeClientRouter(
          profiles: const [
            InnerTubeClientRegistry.androidSdkless,
            InnerTubeClientRegistry.visionOS,
          ],
        ),
        maxRequestAttempts: 1,
      );
      addTearDown(service.dispose);

      final result = await service.resolve(videoId, requireAudioOnly: true);

      expect(result.profile.key, 'visionOS');
      expect(result.format.isAudioOnly, isTrue);
      expect(transport.postCount, 2);
    },
  );

  test(
    'keeps a clear audio format when another format is DRM protected',
    () async {
      final transport = _FakeTransport((_, _) {
        final response = _playerResponse(
          videoId: videoId,
          url: 'https://media.example/clear',
        );
        final adaptive =
            (response['streamingData']
                    as Map<String, dynamic>)['adaptiveFormats']
                as List<Map<String, dynamic>>;
        adaptive.add(<String, dynamic>{
          ...adaptive.single,
          'itag': 141,
          'url': 'https://media.example/drm',
          'bitrate': 256000,
          'drmTrackType': 'DRM_TRACK_TYPE_WIDEVINE',
        });
        return response;
      });
      final service = InnerTubePlaybackService(
        transport: transport,
        validator: _FakeValidator(),
        router: InnerTubeClientRouter(
          profiles: const [InnerTubeClientRegistry.visionOS],
          primaryKey: 'visionOS',
        ),
        maxRequestAttempts: 1,
      );
      addTearDown(service.dispose);

      final result = await service.resolve(videoId);

      expect(result.format.itag, 140);
      expect(result.uri.path, '/clear');
    },
  );

  test('deciphers signature and n with the injected EJS boundary', () async {
    final source = Uri.encodeQueryComponent(
      'https://media.example/audio?n=encrypted-n&expire=2000000000',
    );
    final cipher = 'url=$source&s=encrypted-signature&sp=sig';
    final transport = _FakeTransport(
      (_, _) => _playerResponse(videoId: videoId, signatureCipher: cipher),
    );
    final solved = <EjsChallengeType>[];
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.visionOS],
        primaryKey: 'visionOS',
      ),
      challengeSolver: (playerUrl, type, challenge) async {
        expect(playerUrl, 'https://www.youtube.com/s/player/test/base.js');
        solved.add(type);
        return type == EjsChallengeType.sig ? 'signature' : 'throttled';
      },
      playerUrlLoader: (_) async =>
          Uri.parse('https://www.youtube.com/s/player/test/base.js'),
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.uri.queryParameters['sig'], 'signature');
    expect(result.uri.queryParameters['n'], 'throttled');
    expect(solved, [EjsChallengeType.sig, EjsChallengeType.n]);
  });

  test('classifies an n URL when EJS is unavailable', () async {
    final transport = _FakeTransport(
      (_, _) => _playerResponse(
        videoId: videoId,
        url: 'https://media.example/audio?n=encrypted-n&expire=2000000000',
      ),
    );
    final validator = _FakeValidator();
    var playerUrlLoads = 0;
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: validator,
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.androidSdkless],
        primaryKey: 'androidSdkless',
      ),
      playerUrlLoader: (_) async {
        playerUrlLoads++;
        throw StateError('Player URL must not be loaded without EJS.');
      },
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    Object? thrown;
    try {
      await service.resolve(videoId);
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isA<InnerTubePlaybackException>());
    final error = thrown! as InnerTubePlaybackException;
    expect(error.kind, InnerTubeClientFailureKind.challengeUnavailable);
    final responseError =
        error.failures.single.error as InnerTubeClientResponseException;
    expect(
      responseError.cause,
      isA<InnerTubeChallengeUnavailableException>().having(
        (value) => value.challengeType,
        'challengeType',
        EjsChallengeType.n,
      ),
    );
    expect(playerUrlLoads, 0);
    expect(validator.uris, isEmpty);
  });

  test('classifies an s URL when EJS is unavailable', () async {
    final source = Uri.encodeQueryComponent(
      'https://media.example/audio?expire=2000000000',
    );
    final transport = _FakeTransport(
      (_, _) => _playerResponse(
        videoId: videoId,
        signatureCipher: 'url=$source&s=encrypted-signature&sp=sig',
      ),
    );
    final validator = _FakeValidator();
    var playerUrlLoads = 0;
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: validator,
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.androidSdkless],
        primaryKey: 'androidSdkless',
      ),
      playerUrlLoader: (_) async {
        playerUrlLoads++;
        throw StateError('Player URL must not be loaded without EJS.');
      },
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    Object? thrown;
    try {
      await service.resolve(videoId);
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isA<InnerTubePlaybackException>());
    final error = thrown! as InnerTubePlaybackException;
    expect(error.kind, InnerTubeClientFailureKind.challengeUnavailable);
    final responseError =
        error.failures.single.error as InnerTubeClientResponseException;
    expect(
      responseError.cause,
      isA<InnerTubeChallengeUnavailableException>().having(
        (value) => value.challengeType,
        'challengeType',
        EjsChallengeType.sig,
      ),
    );
    expect(playerUrlLoads, 0);
    expect(validator.uris, isEmpty);
  });

  test(
    'refreshes a missing player URL before solving an unexpected cipher',
    () async {
      final source = Uri.encodeQueryComponent(
        'https://media.example/audio?expire=2000000000',
      );
      final bootstrap = _FakeBootstrapSource(<InnerTubePlayerBootstrap>[
        const InnerTubePlayerBootstrap(
          playerUrl: null,
          visitorData: 'visitor-stale',
          signatureTimestamp: 11111,
          encryptedHostFlags: null,
        ),
        InnerTubePlayerBootstrap(
          playerUrl: Uri.parse(
            'https://www.youtube.com/s/player/refreshed/base.js',
          ),
          visitorData: 'visitor-fresh',
          signatureTimestamp: 22222,
          encryptedHostFlags: null,
        ),
      ]);
      final transport = _FakeTransport(
        (_, _) => _playerResponse(
          videoId: videoId,
          signatureCipher: 'url=$source&s=encrypted-signature&sp=sig',
        ),
      );
      final service = InnerTubePlaybackService(
        transport: transport,
        validator: _FakeValidator(),
        router: InnerTubeClientRouter(
          profiles: const [InnerTubeClientRegistry.visionOS],
          primaryKey: 'visionOS',
        ),
        playerBootstrap: bootstrap,
        challengeSolver: (playerUrl, type, challenge) async {
          expect(
            playerUrl,
            'https://www.youtube.com/s/player/refreshed/base.js',
          );
          expect(type, EjsChallengeType.sig);
          expect(challenge, 'encrypted-signature');
          return 'signature';
        },
        maxRequestAttempts: 1,
      );
      addTearDown(service.dispose);

      final result = await service.resolve(videoId);

      expect(result.uri.queryParameters['sig'], 'signature');
      expect(bootstrap.loads, 2);
      expect(bootstrap.forceRefreshes, <bool>[false, true]);
    },
  );

  test('rejects an untrusted player URL exposed by the watch page', () async {
    final source = Uri.encodeQueryComponent(
      'https://media.example/audio?expire=2000000000',
    );
    final transport = _FakeTransport(
      (_, _) => _playerResponse(
        videoId: videoId,
        signatureCipher: 'url=$source&s=encrypted&sp=sig',
      ),
      getResponse: const InnerTubeHttpResponse(
        statusCode: 200,
        body: r'{"jsUrl":"https://evil.test/base.js"}',
      ),
    );
    var solverCalled = false;
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.visionOS],
        primaryKey: 'visionOS',
      ),
      challengeSolver: (_, _, _) async {
        solverCalled = true;
        return 'unexpected';
      },
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.resolve(videoId),
      throwsA(isA<InnerTubePlaybackException>()),
    );

    expect(transport.getCount, 1);
    expect(solverCalled, isFalse);
  });

  test(
    'retries a rejected video-bound GVS token with visitor binding',
    () async {
      final now = DateTime.utc(2026, 8, 31, 12);
      final bindings = <YoutubePoTokenBinding>[];
      final transport = _FakeTransport((_, request) {
        expect(request, isNot(contains('serviceIntegrityDimensions')));
        return _playerResponse(
          videoId: videoId,
          url: 'https://media.example/audio',
        );
      });
      final validator = _FakeValidator((uri) {
        if (uri.queryParameters['pot'] == 'gvs-videoId') {
          throw const InnerTubeStreamValidationException(
            'rejected',
            statusCode: 403,
          );
        }
      });
      final service = InnerTubePlaybackService(
        transport: transport,
        validator: validator,
        router: InnerTubeClientRouter(
          profiles: const [InnerTubeClientRegistry.mweb],
          primaryKey: 'mweb',
        ),
        challengeSolver: (_, _, challenge) async => challenge,
        playerUrlLoader: (_) async =>
            Uri.parse('https://www.youtube.com/s/player/test/base.js'),
        poTokenLoader: ({required videoId, required requirements}) async {
          bindings.add(requirements.gvsBinding);
          expect(requirements.player, isFalse);
          return YoutubePoTokenData(
            visitorData: 'visitor',
            playerRequestPoToken: null,
            streamingDataPoToken: 'gvs-${requirements.gvsBinding.name}',
            expiresAt: now.add(const Duration(minutes: 10)),
            playerBinding: requirements.playerBinding,
            gvsBinding: requirements.gvsBinding,
          );
        },
        maxRequestAttempts: 1,
        clock: () => now,
      );
      addTearDown(service.dispose);

      final result = await service.resolve(videoId);

      expect(result.uri.queryParameters['pot'], 'gvs-visitorData');
      expect(bindings, [
        YoutubePoTokenBinding.videoId,
        YoutubePoTokenBinding.visitorData,
      ]);
      expect(validator.uris, hasLength(2));
      expect(
        result.expiresAt,
        now.add(const Duration(minutes: 9, seconds: 30)),
      );
    },
  );

  test('sends HTML5 playback context and the matching player STS', () async {
    final transport = _FakeTransport((_, request) {
      expect(request['playbackContext'], <String, Object?>{
        'contentPlaybackContext': <String, Object?>{
          'html5Preference': 'HTML5_PREF_WANTS',
          'signatureTimestamp': 20348,
        },
      });
      return _playerResponse(
        videoId: videoId,
        url: 'https://media.example/audio',
      );
    });
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: InnerTubeClientRouter(
        profiles: [_asStable(InnerTubeClientRegistry.tv)],
        primaryKey: 'tv',
      ),
      challengeSolver: (_, _, challenge) async => 'solved:$challenge',
      playerUrlLoader: (_) async =>
          Uri.parse('https://www.youtube.com/s/player/test/base.js'),
      signatureTimestampLoader: (_) async => 20348,
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.profile.key, 'tv');
    expect(transport.postCount, 1);
  });

  test('binds an embedded player request to the exact video', () async {
    final bootstrap = _FakeBootstrapSource(<InnerTubePlayerBootstrap>[
      InnerTubePlayerBootstrap(
        playerUrl: Uri.parse(
          'https://www.youtube.com/s/player/embed-test/base.js',
        ),
        visitorData: 'embed-visitor',
        signatureTimestamp: 20348,
        encryptedHostFlags: 'encrypted-flags',
        clientVersion: '2.20260831.01.00',
        clientName: 'WEB_EMBEDDED_PLAYER',
        clientId: 56,
        embeddedPlayerEncryptedContext: 'embedded-context',
      ),
    ]);
    final transport = _FakeTransport((headers, request) {
      expect(headers['Referer'], 'https://www.reddit.com/');
      expect(headers['X-Origin'], 'https://www.youtube.com');
      expect(headers['Accept-Language'], 'en-US,en;q=0.9');
      expect(headers['X-YouTube-Client-Version'], '2.20260831.01.00');
      expect(request, isNot(contains('thirdParty')));
      final context = Map<String, Object?>.from(request['context']! as Map);
      expect(context['thirdParty'], <String, Object?>{
        'embedUrl': 'https://www.reddit.com/',
        'embeddedPlayerContext': <String, Object?>{
          'embeddedPlayerEncryptedContext': 'embedded-context',
          'ancestorOriginsSupported': false,
        },
      });
      expect((context['client'] as Map)['clientVersion'], '2.20260831.01.00');
      expect(request['videoCheckOk'], isTrue);
      expect(request['playbackContext'], <String, Object?>{
        'contentPlaybackContext': <String, Object?>{
          'html5Preference': 'HTML5_PREF_WANTS',
          'signatureTimestamp': 20348,
          'encryptedHostFlags': 'encrypted-flags',
        },
      });
      return _playerResponse(
        videoId: videoId,
        url: 'https://media.example/audio',
      );
    });
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.webEmbedded],
        primaryKey: 'webEmbedded',
      ),
      visitorDataStore: _VisitorStore(),
      playerBootstrap: bootstrap,
      challengeSolver: (_, _, challenge) async => 'solved:$challenge',
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.profile.key, 'webEmbedded');
    expect(bootstrap.loads, 1);
  });

  test('refreshes a missing player URL as one coherent snapshot', () async {
    final bootstrap = _FakeBootstrapSource(<InnerTubePlayerBootstrap>[
      const InnerTubePlayerBootstrap(
        playerUrl: null,
        visitorData: 'visitor-stale',
        signatureTimestamp: 11111,
        encryptedHostFlags: 'flags-stale',
        clientVersion: '2.20260830.00.00',
        clientName: 'WEB_EMBEDDED_PLAYER',
        clientId: 56,
        embeddedPlayerEncryptedContext: 'context-stale',
      ),
      InnerTubePlayerBootstrap(
        playerUrl: Uri.parse(
          'https://www.youtube.com/s/player/refreshed/base.js',
        ),
        visitorData: 'visitor-fresh',
        signatureTimestamp: 22222,
        encryptedHostFlags: 'flags-fresh',
        clientVersion: '2.20260831.01.00',
        clientName: 'WEB_EMBEDDED_PLAYER',
        clientId: 56,
        embeddedPlayerEncryptedContext: 'context-fresh',
      ),
    ]);
    final store = _VisitorStore();
    final transport = _FakeTransport((headers, request) {
      expect(headers['X-Goog-Visitor-Id'], 'visitor-fresh');
      expect(headers['X-YouTube-Client-Version'], '2.20260831.01.00');
      final context = Map<String, Object?>.from(request['context']! as Map);
      expect(context['thirdParty'], <String, Object?>{
        'embedUrl': 'https://www.reddit.com/',
        'embeddedPlayerContext': <String, Object?>{
          'embeddedPlayerEncryptedContext': 'context-fresh',
          'ancestorOriginsSupported': false,
        },
      });
      expect(request['playbackContext'], <String, Object?>{
        'contentPlaybackContext': <String, Object?>{
          'html5Preference': 'HTML5_PREF_WANTS',
          'signatureTimestamp': 22222,
          'encryptedHostFlags': 'flags-fresh',
        },
      });
      return _playerResponse(
        videoId: videoId,
        url: 'https://media.example/audio',
      );
    });
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.webEmbedded],
        primaryKey: 'webEmbedded',
      ),
      visitorDataStore: store,
      playerBootstrap: bootstrap,
      challengeSolver: (_, _, challenge) async => 'solved:$challenge',
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.profile.key, 'webEmbedded');
    expect(store.value, 'visitor-fresh');
    expect(bootstrap.loads, 2);
    expect(bootstrap.forceRefreshes, <bool>[false, true]);
  });

  test('does not replace a version-pinned fallback from bootstrap', () async {
    final bootstrap = _FakeBootstrapSource(<InnerTubePlayerBootstrap>[
      InnerTubePlayerBootstrap(
        playerUrl: Uri.parse(
          'https://www.youtube.com/s/player/tv-test/base.js',
        ),
        visitorData: 'tv-visitor',
        signatureTimestamp: 20348,
        encryptedHostFlags: null,
        clientVersion: '7.20260826.15.00',
        clientName: 'TVHTML5',
        clientId: 7,
      ),
    ]);
    final transport = _FakeTransport((headers, request) {
      expect(headers['X-YouTube-Client-Version'], '5.20260707');
      final context = Map<String, Object?>.from(request['context']! as Map);
      expect((context['client'] as Map)['clientVersion'], '5.20260707');
      return _playerResponse(
        videoId: videoId,
        url: 'https://media.example/audio',
      );
    });
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: InnerTubeClientRouter(
        profiles: [_asStable(InnerTubeClientRegistry.tvDowngraded)],
        primaryKey: 'tvDowngraded',
      ),
      visitorDataStore: _VisitorStore(),
      playerBootstrap: bootstrap,
      challengeSolver: (_, _, challenge) async => 'solved:$challenge',
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.profile.key, 'tvDowngraded');
    expect(bootstrap.loads, 1);
  });

  test(
    'bootstraps and persists visitor identity before a JS-less request',
    () async {
      final store = _VisitorStore();
      final bootstrap = _FakeBootstrapSource(<InnerTubePlayerBootstrap>[
        const InnerTubePlayerBootstrap(
          playerUrl: null,
          visitorData: 'visitor-fresh',
          signatureTimestamp: null,
          encryptedHostFlags: null,
        ),
      ]);
      final transport = _FakeTransport((headers, request) {
        expect(headers['X-Goog-Visitor-Id'], 'visitor-fresh');
        expect(
          ((request['context'] as Map)['client'] as Map)['visitorData'],
          'visitor-fresh',
        );
        return _playerResponse(
          videoId: videoId,
          url: 'https://media.example/audio',
        );
      });
      final service = InnerTubePlaybackService(
        transport: transport,
        validator: _FakeValidator(),
        router: InnerTubeClientRouter(
          profiles: const [InnerTubeClientRegistry.visionOS],
          primaryKey: 'visionOS',
        ),
        visitorDataStore: store,
        playerBootstrap: bootstrap,
        maxRequestAttempts: 1,
      );
      addTearDown(service.dispose);

      await service.resolve(videoId);

      expect(store.value, 'visitor-fresh');
      expect(bootstrap.loads, 1);
    },
  );

  test(
    'a failed optional visitor bootstrap does not block a direct client',
    () async {
      final bootstrap = _ThrowingBootstrapSource();
      final transport = _FakeTransport((headers, request) {
        expect(headers, isNot(contains('X-Goog-Visitor-Id')));
        expect(
          (request['context'] as Map)['client'] as Map,
          isNot(contains('visitorData')),
        );
        return _playerResponse(
          videoId: videoId,
          url: 'https://media.example/audio',
        );
      });
      final service = InnerTubePlaybackService(
        transport: transport,
        validator: _FakeValidator(),
        router: InnerTubeClientRouter(
          profiles: const [InnerTubeClientRegistry.visionOS],
          primaryKey: 'visionOS',
        ),
        visitorDataStore: _VisitorStore(),
        playerBootstrap: bootstrap,
        maxRequestAttempts: 1,
      );
      addTearDown(service.dispose);

      final result = await service.resolve(videoId);

      expect(result.profile.key, 'visionOS');
      expect(bootstrap.loads, 1);
      expect(transport.postCount, 1);
    },
  );

  test('refreshes visitor once after a classified bot response', () async {
    final store = _VisitorStore('visitor-stale');
    final bootstrap = _FakeBootstrapSource(<InnerTubePlayerBootstrap>[
      const InnerTubePlayerBootstrap(
        playerUrl: null,
        visitorData: 'visitor-fresh',
        signatureTimestamp: null,
        encryptedHostFlags: null,
      ),
    ]);
    final visitors = <String?>[];
    final transport = _FakeTransport((headers, _) {
      visitors.add(headers['X-Goog-Visitor-Id']);
      if (visitors.length == 1) {
        final blocked = _playerResponse(
          videoId: videoId,
          url: 'https://media.example/blocked',
        );
        blocked['playabilityStatus'] = <String, Object?>{
          'status': 'LOGIN_REQUIRED',
          'reason': "Sign in to confirm you're not a bot",
        };
        return blocked;
      }
      return _playerResponse(
        videoId: videoId,
        url: 'https://media.example/audio',
      );
    });
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.visionOS],
        primaryKey: 'visionOS',
      ),
      visitorDataStore: store,
      playerBootstrap: bootstrap,
      maxRequestAttempts: 1,
    );
    addTearDown(service.dispose);

    await service.resolve(videoId);

    expect(visitors, <String?>['visitor-stale', 'visitor-fresh']);
    expect(store.value, 'visitor-fresh');
    expect(bootstrap.invalidations, 1);
  });

  test('escalates optional player PO only after a bot response', () async {
    final now = DateTime.utc(2026, 8, 31, 12);
    final requests = <Map<String, dynamic>>[];
    final tokenRequirements = <YoutubePoTokenRequirements>[];
    final transport = _FakeTransport((_, request) {
      requests.add(request);
      if (requests.length == 1) {
        final blocked = _playerResponse(
          videoId: videoId,
          url: 'https://media.example/blocked',
        );
        blocked['playabilityStatus'] = <String, Object?>{
          'status': 'LOGIN_REQUIRED',
          'reason': "Sign in to confirm you're not a bot",
        };
        return blocked;
      }
      return _playerResponse(
        videoId: videoId,
        url: 'https://media.example/audio',
      );
    });
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.mweb],
        primaryKey: 'mweb',
      ),
      challengeSolver: (_, _, challenge) async => challenge,
      playerUrlLoader: (_) async =>
          Uri.parse('https://www.youtube.com/s/player/test/base.js'),
      poTokenLoader: ({required videoId, required requirements}) async {
        tokenRequirements.add(requirements);
        return YoutubePoTokenData(
          visitorData: 'visitor',
          playerRequestPoToken: requirements.player ? 'player-fresh' : null,
          streamingDataPoToken: 'gvs-fresh',
          expiresAt: now.add(const Duration(minutes: 10)),
          playerBinding: requirements.playerBinding,
          gvsBinding: requirements.gvsBinding,
        );
      },
      maxRequestAttempts: 1,
      clock: () => now,
    );
    addTearDown(service.dispose);

    final result = await service.resolve(videoId);

    expect(result.profile.key, 'mweb');
    expect(requests, hasLength(2));
    expect(requests.first, isNot(contains('serviceIntegrityDimensions')));
    expect(requests.last['serviceIntegrityDimensions'], <String, Object?>{
      'poToken': 'player-fresh',
    });
    expect(tokenRequirements, hasLength(2));
    expect(tokenRequirements.first.player, isFalse);
    expect(tokenRequirements.last.player, isTrue);
  });

  test('circuit-breaks a shared Web PO failure across profiles', () async {
    var now = DateTime.utc(2026, 8, 31, 12);
    var tokenLoads = 0;
    final router = InnerTubeClientRouter(
      profiles: const [
        InnerTubeClientRegistry.mweb,
        InnerTubeClientRegistry.webMusic,
        InnerTubeClientRegistry.visionOS,
      ],
      primaryKey: 'mweb',
      clock: () => now,
    );
    final service = InnerTubePlaybackService(
      transport: _FakeTransport(
        (_, request) => _playerResponse(
          videoId: request['videoId']! as String,
          url: 'https://media.example/audio',
        ),
      ),
      validator: _FakeValidator(),
      router: router,
      challengeSolver: (_, _, challenge) async => 'solved:$challenge',
      playerUrlLoader: (_) async =>
          Uri.parse('https://www.youtube.com/s/player/test/base.js'),
      poTokenLoader: ({required videoId, required requirements}) async {
        tokenLoads++;
        throw const PoTokenException('GenerateIT unavailable');
      },
      maxRequestAttempts: 1,
      webPoFailureCooldown: const Duration(minutes: 2),
      clock: () => now,
    );
    addTearDown(service.dispose);

    expect((await service.resolve(videoId)).profile.key, 'visionOS');
    expect(tokenLoads, 1);
    expect(router.healthFor('mweb').consecutiveFailures, 0);
    expect(router.healthFor('webMusic').consecutiveFailures, 0);

    expect((await service.resolve('abcdefghijk')).profile.key, 'visionOS');
    expect(tokenLoads, 1);

    now = now.add(const Duration(minutes: 3));
    expect((await service.resolve('mnopqrstuvw')).profile.key, 'visionOS');
    expect(tokenLoads, 2);
  });

  test(
    'rechecks the shared Web PO breaker between concurrent profiles',
    () async {
      const waitingVideoId = 'abcdefghijk';
      const breakerVideoId = 'mnopqrstuvw';
      final plain = _profile(key: 'plain', clientName: 'WEB', clientId: 1);
      final waitingProfileStarted = Completer<void>();
      final releaseWaitingProfile = Completer<void>();
      var tokenLoads = 0;
      final router = InnerTubeClientRouter(
        profiles: [plain, InnerTubeClientRegistry.mweb],
        primaryKey: plain.key,
      );
      final transport = _FakeTransport((headers, request) async {
        final requestedVideoId = request['videoId']! as String;
        if (headers['X-YouTube-Client-Name'] == '1') {
          if (requestedVideoId == waitingVideoId) {
            waitingProfileStarted.complete();
            await releaseWaitingProfile.future;
          }
          return _playerResponse(
            videoId: 'zzzzzzzzzzz',
            url: 'https://media.example/mismatched',
          );
        }
        throw StateError('Web PO should fail or be skipped before player I/O.');
      });
      final service = InnerTubePlaybackService(
        transport: transport,
        validator: _FakeValidator(),
        router: router,
        challengeSolver: (_, _, challenge) async => 'solved:$challenge',
        playerUrlLoader: (_) async =>
            Uri.parse('https://www.youtube.com/s/player/test/base.js'),
        poTokenLoader: ({required videoId, required requirements}) async {
          tokenLoads++;
          throw const PoTokenException('GenerateIT unavailable');
        },
        maxRequestAttempts: 1,
        webPoFailureCooldown: const Duration(minutes: 2),
      );
      addTearDown(service.dispose);

      final waitingResolve = service.resolve(waitingVideoId);
      await waitingProfileStarted.future;

      await expectLater(
        service.resolve(breakerVideoId),
        throwsA(isA<InnerTubePlaybackException>()),
      );
      expect(tokenLoads, 1);

      releaseWaitingProfile.complete();
      await expectLater(
        waitingResolve,
        throwsA(isA<InnerTubePlaybackException>()),
      );

      expect(tokenLoads, 1);
      expect(router.healthFor('mweb').consecutiveFailures, 0);
    },
  );

  test('circuit-breaks shared EJS capacity failures until cooldown', () async {
    var now = DateTime.utc(2026, 8, 31, 12);
    var solverCalls = 0;
    final router = InnerTubeClientRouter(
      profiles: [
        _asStable(InnerTubeClientRegistry.tv),
        _asStable(InnerTubeClientRegistry.tvDowngraded),
      ],
      primaryKey: 'tv',
      clock: () => now,
    );
    final transport = _FakeTransport(
      (_, request) => _playerResponse(
        videoId: request['videoId']! as String,
        url: 'https://media.example/audio?n=challenge',
      ),
    );
    final service = InnerTubePlaybackService(
      transport: transport,
      validator: _FakeValidator(),
      router: router,
      challengeSolver: (_, _, _) async {
        solverCalls++;
        throw const EjsSolverException('JavaScript runtime unavailable');
      },
      playerUrlLoader: (_) async =>
          Uri.parse('https://www.youtube.com/s/player/test/base.js'),
      maxRequestAttempts: 1,
      ejsFailureCooldown: const Duration(minutes: 2),
      clock: () => now,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.resolve(videoId),
      throwsA(isA<InnerTubePlaybackException>()),
    );
    expect(solverCalls, 1);
    expect(transport.postCount, 1);
    expect(router.healthFor('tv').consecutiveFailures, 0);
    expect(router.healthFor('tvDowngraded').consecutiveFailures, 0);

    await expectLater(
      service.resolve('abcdefghijk'),
      throwsA(isA<InnerTubePlaybackException>()),
    );
    expect(solverCalls, 1);
    expect(transport.postCount, 1);

    now = now.add(const Duration(minutes: 3));
    await expectLater(
      service.resolve('mnopqrstuvw'),
      throwsA(isA<InnerTubePlaybackException>()),
    );
    expect(solverCalls, 2);
    expect(transport.postCount, 2);
  });
}

InnerTubeClientProfile _profile({
  required String key,
  required String clientName,
  required int clientId,
}) => InnerTubeClientProfile(
  key: key,
  clientName: clientName,
  clientVersion: '1.0',
  clientId: clientId,
  host: 'www.youtube.com',
  origin: 'https://www.youtube.com',
  userAgent: 'BStream test',
  capabilities: const InnerTubeClientCapabilities(
    playerJavaScript: InnerTubePlayerJavaScriptRequirement.notRequired,
    playerPoToken: InnerTubePoTokenRequirement.notRequired,
    streamingDataPoToken: InnerTubePoTokenRequirement.notRequired,
    poTokenProvider: InnerTubePoTokenProvider.none,
  ),
  availability: InnerTubeClientAvailability.stable,
);

InnerTubeClientProfile _asStable(InnerTubeClientProfile profile) =>
    InnerTubeClientProfile(
      key: profile.key,
      clientName: profile.clientName,
      clientVersion: profile.clientVersion,
      clientId: profile.clientId,
      host: profile.host,
      origin: profile.origin,
      userAgent: profile.userAgent,
      capabilities: profile.capabilities,
      availability: InnerTubeClientAvailability.stable,
      isEmbedded: profile.isEmbedded,
      allowDynamicClientVersion: profile.allowDynamicClientVersion,
      contextValues: profile.contextValues,
      requestContextValues: profile.requestContextValues,
    );

Map<String, dynamic> _playerResponse({
  required String videoId,
  String? url,
  String? signatureCipher,
}) => <String, dynamic>{
  'playabilityStatus': <String, dynamic>{'status': 'OK'},
  'videoDetails': <String, dynamic>{
    'videoId': videoId,
    'title': 'Test',
    'author': 'BStream',
    'lengthSeconds': '120',
  },
  'streamingData': <String, dynamic>{
    'expiresInSeconds': '3600',
    'adaptiveFormats': <Map<String, dynamic>>[
      <String, dynamic>{
        'itag': 140,
        'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
        'bitrate': 129000,
        'contentLength': '2000000',
        'url': ?url,
        'signatureCipher': ?signatureCipher,
      },
    ],
  },
};

final class _FakeTransport implements InnerTubeTransport {
  _FakeTransport(this.handler, {this.getResponse});

  final FutureOr<Map<String, dynamic>> Function(
    Map<String, String> headers,
    Map<String, dynamic> request,
  )
  handler;
  final InnerTubeHttpResponse? getResponse;
  int postCount = 0;
  int getCount = 0;

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) async {
    postCount += 1;
    final response = await handler(
      headers,
      Map<String, dynamic>.from(body as Map),
    );
    return InnerTubeHttpResponse(statusCode: 200, body: jsonEncode(response));
  }

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    getCount += 1;
    return getResponse ?? (throw UnimplementedError());
  }

  @override
  void close() {}
}

final class _FakeValidator implements InnerTubeStreamValidator {
  _FakeValidator([this.onValidate]);

  final void Function(Uri uri)? onValidate;
  final List<Uri> uris = [];

  @override
  Future<InnerTubeStreamProbe> validate(
    Uri uri, {
    required Map<String, String> headers,
    int? contentLength,
  }) async {
    uris.add(uri);
    onValidate?.call(uri);
    return InnerTubeStreamProbe(
      statusCode: 206,
      elapsed: const Duration(milliseconds: 1),
      probedOffset: 1024 * 1024,
      receivedBytes: 1,
      contentLength: contentLength,
    );
  }
}

final class _VisitorStore implements InnerTubeVisitorDataStore {
  _VisitorStore([this.value]);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String visitorData) async {
    value = visitorData;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

final class _FakeBootstrapSource implements InnerTubePlayerBootstrapSource {
  _FakeBootstrapSource(this.values);

  final List<InnerTubePlayerBootstrap> values;
  int loads = 0;
  int invalidations = 0;
  final List<bool> forceRefreshes = <bool>[];

  @override
  Future<InnerTubePlayerBootstrap> load(
    String videoId, {
    bool forceRefresh = false,
    bool embedded = false,
    InnerTubePlayerBootstrapPage? page,
    String? userAgent,
  }) async {
    final index = loads.clamp(0, values.length - 1);
    loads++;
    forceRefreshes.add(forceRefresh);
    return values[index];
  }

  @override
  void invalidate() {
    invalidations++;
  }
}

final class _ThrowingBootstrapSource implements InnerTubePlayerBootstrapSource {
  int loads = 0;

  @override
  Future<InnerTubePlayerBootstrap> load(
    String videoId, {
    bool forceRefresh = false,
    bool embedded = false,
    InnerTubePlayerBootstrapPage? page,
    String? userAgent,
  }) async {
    loads++;
    throw TimeoutException('optional bootstrap timed out');
  }

  @override
  void invalidate() {}
}
