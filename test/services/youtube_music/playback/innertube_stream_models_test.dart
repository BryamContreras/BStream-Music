import 'package:bstream_music/services/youtube_music/playback/innertube_stream_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selectPreferredInnerTubeAudio', () {
    test('prefers default, non-DRC, audio-only MP4/AAC in that order', () {
      final formats = <InnerTubeAudioFormat>[
        _format(
          itag: 251,
          container: 'webm',
          codec: 'opus',
          bitrate: 192000,
          isDefault: true,
          isDrc: true,
        ),
        _format(itag: 140, bitrate: 128000, isDefault: true),
        _format(itag: 141, bitrate: 256000, isDefault: false),
        _format(itag: 18, bitrate: 96000, isDefault: true, audioOnly: false),
      ];

      expect(selectPreferredInnerTubeAudio(formats)?.itag, 140);
    });

    test(
      'uses bitrate as a deterministic tie-break within preferred group',
      () {
        final formats = <InnerTubeAudioFormat>[
          _format(itag: 139, bitrate: 48000),
          _format(itag: 140, bitrate: 128000),
        ];

        expect(selectPreferredInnerTubeAudio(formats)?.itag, 140);
      },
    );

    test('excludes DRM unless explicitly allowed', () {
      final drm = _format(itag: 140, bitrate: 128000, isDrm: true);

      expect(
        selectPreferredInnerTubeAudio(<InnerTubeAudioFormat>[drm]),
        isNull,
      );
      expect(
        selectPreferredInnerTubeAudio(<InnerTubeAudioFormat>[
          drm,
        ], allowDrm: true),
        same(drm),
      );
    });

    test('can require an already resolved URI', () {
      final unresolved = InnerTubeAudioFormat(
        source: InnerTubeFormatSource.adaptiveFormats,
        itag: 140,
        mimeType: 'audio/mp4',
        container: 'mp4',
        codecs: const <String>['mp4a.40.2'],
        cipher: InnerTubeStreamCipher(
          uri: Uri.parse('https://media.example.test/audio'),
          encryptedSignature: 'encrypted',
        ),
      );

      expect(
        selectPreferredInnerTubeAudio(<InnerTubeAudioFormat>[unresolved]),
        same(unresolved),
      );
      expect(
        selectPreferredInnerTubeAudio(<InnerTubeAudioFormat>[
          unresolved,
        ], requireResolvedUri: true),
        isNull,
      );
    });

    test('resolves a cipher carrying a plain signature', () {
      final cipher = InnerTubeStreamCipher(
        uri: Uri.parse('https://media.example.test/audio?foo=bar'),
        signature: 'plain',
        signatureParameter: 'sig',
      );

      expect(cipher.requiresSignatureDecipher, isFalse);
      expect(cipher.resolvedUri?.queryParameters['foo'], 'bar');
      expect(cipher.resolvedUri?.queryParameters['sig'], 'plain');
    });

    test('AVFoundation policy accepts audio-only and muxed MP4/AAC', () {
      final audioOnly = _format(itag: 140, bitrate: 128000);
      final muxed = _format(itag: 18, bitrate: 96000, audioOnly: false);

      expect(isAvFoundationCompatibleInnerTubeAudio(audioOnly), isTrue);
      expect(isAvFoundationCompatibleInnerTubeAudio(muxed), isTrue);
    });

    test('AVFoundation policy accepts an explicit raw AAC stream', () {
      final aac = InnerTubeAudioFormat(
        source: InnerTubeFormatSource.adaptiveFormats,
        itag: 139,
        uri: Uri.parse('https://media.example.test/139'),
        mimeType: 'audio/aac',
        container: 'aac',
        codecs: const <String>[],
        bitrate: 48000,
      );

      expect(isAvFoundationCompatibleInnerTubeAudio(aac), isTrue);
    });

    test('AVFoundation policy rejects WebM/Opus', () {
      final webm = _format(
        itag: 251,
        container: 'webm',
        codec: 'opus',
        bitrate: 192000,
      );

      expect(isAvFoundationCompatibleInnerTubeAudio(webm), isFalse);
    });
  });
}

InnerTubeAudioFormat _format({
  required int itag,
  String container = 'mp4',
  String codec = 'mp4a.40.2',
  required int bitrate,
  bool? isDefault,
  bool isDrc = false,
  bool isDrm = false,
  bool audioOnly = true,
}) {
  return InnerTubeAudioFormat(
    source: audioOnly
        ? InnerTubeFormatSource.adaptiveFormats
        : InnerTubeFormatSource.formats,
    itag: itag,
    uri: Uri.parse('https://media.example.test/$itag'),
    mimeType: audioOnly ? 'audio/$container' : 'video/$container',
    container: container,
    codecs: audioOnly ? <String>[codec] : <String>['avc1.42001E', codec],
    bitrate: bitrate,
    audioTrack: InnerTubeAudioTrack(
      id: isDefault == false ? 'es.1' : 'en.1',
      displayName: isDefault == false ? 'Spanish' : 'English',
      isDefault: isDefault,
    ),
    isDrc: isDrc,
    isDrm: isDrm,
  );
}
