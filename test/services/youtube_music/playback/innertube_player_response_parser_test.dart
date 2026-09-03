import 'package:bstream_music/services/youtube_music/playback/innertube_player_response_parser.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = InnerTubePlayerResponseParser();

  group('InnerTubePlayerResponseParser', () {
    test('parses direct, ciphered, muxed, manifest and track metadata', () {
      final encryptedCipher = Uri(
        queryParameters: <String, String>{
          'url': 'https://media.example.test/ciphered?clen=444',
          's': 'encrypted-signature',
          'sp': 'sig',
        },
      ).query;
      final payload = <String, dynamic>{
        'playabilityStatus': <String, dynamic>{'status': 'OK'},
        'videoDetails': <String, dynamic>{
          'videoId': 'dQw4w9WgXcQ',
          'title': 'Example',
          'author': 'Artist',
          'lengthSeconds': '213',
          'isLiveContent': false,
        },
        'streamingData': <String, dynamic>{
          'expiresInSeconds': '21600',
          'hlsManifestUrl': 'https://manifest.example.test/live.m3u8',
          'dashManifestUrl': 'https://manifest.example.test/live.mpd',
          'formats': <Object?>[
            <String, dynamic>{
              'itag': 18,
              'url': 'https://media.example.test/muxed?clen=1000',
              'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
              'bitrate': 96000,
              'audioTrack': <String, dynamic>{
                'id': 'en.1',
                'displayName': <String, dynamic>{'simpleText': 'English'},
                'audioIsDefault': true,
              },
            },
            <String, dynamic>{
              'itag': 137,
              'url': 'https://media.example.test/video-only',
              'mimeType': 'video/mp4; codecs="avc1.640028"',
              'bitrate': 2000000,
            },
          ],
          'adaptiveFormats': <Object?>[
            <String, dynamic>{
              'itag': 140,
              'url': 'https://media.example.test/aac',
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'bitrate': 128000,
              'averageBitrate': '127500',
              'contentLength': '222',
              'approxDurationMs': '213000',
              'audioSampleRate': '44100',
              'audioChannels': 2,
              'audioTrack': <String, dynamic>{
                'id': 'en.1',
                'displayName': <String, dynamic>{
                  'runs': <Object?>[
                    <String, dynamic>{'text': 'English'},
                  ],
                },
                'audioIsDefault': true,
              },
            },
            <String, dynamic>{
              'itag': 251,
              'url': 'https://media.example.test/opus',
              'mimeType': 'audio/webm; codecs="opus"',
              'bitrate': 160000,
              'isDrc': true,
              'audioTrack': <String, dynamic>{
                'id': 'en.1.drc',
                'audioIsDefault': true,
              },
            },
            <String, dynamic>{
              'itag': 141,
              'signatureCipher': encryptedCipher,
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'bitrate': 256000,
              'audioTrack': <String, dynamic>{
                'id': 'es.1',
                'audioIsDefault': false,
              },
            },
            'malformed',
          ],
        },
      };

      final response = parser.parse(payload, clientId: 'visionOS');

      expect(response.clientId, 'visionOS');
      expect(response.isPlayable, isTrue);
      expect(response.videoId, 'dQw4w9WgXcQ');
      expect(response.title, 'Example');
      expect(response.author, 'Artist');
      expect(response.duration, const Duration(seconds: 213));
      expect(response.expiresIn, const Duration(hours: 6));
      expect(response.formats.map((format) => format.itag), <int>[18]);
      expect(response.adaptiveFormats.map((format) => format.itag), <int>[
        140,
        251,
        141,
      ]);
      expect(response.audioFormats, hasLength(4));
      expect(response.hlsManifestUri?.path, '/live.m3u8');
      expect(response.dashManifestUri?.path, '/live.mpd');

      final aac = response.adaptiveFormats.first;
      expect(aac.mime, 'audio/mp4');
      expect(aac.container, 'mp4');
      expect(aac.codecs, <String>['mp4a.40.2']);
      expect(aac.contentLength, 222);
      expect(aac.audioTrack?.displayName, 'English');
      expect(aac.isDefaultAudio, isTrue);

      final drc = response.adaptiveFormats[1];
      expect(drc.isDrc, isTrue);

      final ciphered = response.adaptiveFormats.last;
      expect(ciphered.uri, isNull);
      expect(ciphered.cipher?.uri?.path, '/ciphered');
      expect(ciphered.cipher?.encryptedSignature, 'encrypted-signature');
      expect(ciphered.cipher?.signatureParameter, 'sig');
      expect(ciphered.contentLength, 444);
      expect(ciphered.requiresSignatureDecipher, isTrue);

      expect(response.selectPreferredAudio()?.itag, 140);
    });

    test('parses the alternate cipher field and a plain signature', () {
      final cipher = Uri(
        queryParameters: <String, String>{
          'url': 'https://media.example.test/audio?foo=bar',
          'sig': 'plain-signature',
          'sp': 'lsig',
        },
      ).query;
      final response = parser.parse(<String, dynamic>{
        'playabilityStatus': <String, dynamic>{'status': 'OK'},
        'streamingData': <String, dynamic>{
          'adaptiveFormats': <Object?>[
            <String, dynamic>{
              'itag': 140,
              'cipher': cipher,
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
            },
          ],
        },
      }, clientId: 'web');

      final format = response.audioFormats.single;
      expect(format.requiresSignatureDecipher, isFalse);
      expect(format.hasResolvedUri, isTrue);
      expect(format.resolvedUri?.queryParameters['foo'], 'bar');
      expect(format.resolvedUri?.queryParameters['lsig'], 'plain-signature');
    });

    test('classifies playability failures with readable subreasons', () {
      final cases = <(String, String, InnerTubePlayability)>[
        (
          'LOGIN_REQUIRED',
          'Sign in to confirm your age',
          InnerTubePlayability.ageRestricted,
        ),
        (
          'UNPLAYABLE',
          'This is a private video',
          InnerTubePlayability.privateVideo,
        ),
        (
          'UNPLAYABLE',
          'Available to members only',
          InnerTubePlayability.membersOnly,
        ),
        (
          'UNPLAYABLE',
          'Not available in your country',
          InnerTubePlayability.regionRestricted,
        ),
        (
          'LIVE_STREAM_OFFLINE',
          'This live stream is offline',
          InnerTubePlayability.liveStreamOffline,
        ),
        ('ERROR', 'Temporary player failure', InnerTubePlayability.error),
      ];

      for (final (status, reason, expected) in cases) {
        final response = parser.parse(<String, dynamic>{
          'playabilityStatus': <String, dynamic>{
            'status': status,
            'errorScreen': <String, dynamic>{
              'playerErrorMessageRenderer': <String, dynamic>{
                'subreason': <String, dynamic>{
                  'runs': <Object?>[
                    <String, dynamic>{'text': reason},
                  ],
                },
              },
            },
          },
        }, clientId: 'test');

        expect(response.playability.value, expected, reason: reason);
        expect(response.playability.subreason, reason);
        expect(response.isPlayable, isFalse);
      }
    });

    test('propagates response DRM and rejects DRM in default selection', () {
      final response = parser.parse(<String, dynamic>{
        'playabilityStatus': <String, dynamic>{'status': 'OK'},
        'streamingData': <String, dynamic>{
          'licenseInfos': <Object?>[
            <String, dynamic>{'drmFamily': 'WIDEVINE'},
          ],
          'adaptiveFormats': <Object?>[
            <String, dynamic>{
              'itag': 140,
              'url': 'https://media.example.test/drm',
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
            },
          ],
        },
      }, clientId: 'web');

      expect(response.hasDrm, isTrue);
      expect(response.audioFormats.single.isDrm, isTrue);
      expect(response.selectPreferredAudio(), isNull);
      expect(response.selectPreferredAudio(allowDrm: true)?.itag, 140);
    });

    test('is tolerant of absent and malformed optional fields', () {
      final response = parser.parse(<String, dynamic>{
        'streamingData': <String, dynamic>{
          'hlsManifestUrl': 'javascript:invalid',
          'adaptiveFormats': <Object?>[
            null,
            'bad',
            <String, dynamic>{'itag': 'not-an-int', 'mimeType': 'audio/mp4'},
          ],
        },
      }, clientId: 'test');

      expect(response.playability.value, InnerTubePlayability.unknown);
      expect(response.audioFormats, isEmpty);
      expect(response.hlsManifestUri, isNull);
    });

    test('requires a non-empty client identifier', () {
      expect(
        () => parser.parse(<String, dynamic>{}, clientId: ' '),
        throwsArgumentError,
      );
    });
  });
}
