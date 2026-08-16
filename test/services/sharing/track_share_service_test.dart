import 'dart:ui';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/sharing/track_share_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const videoId = 'dQw4w9WgXcQ';

  TrackInfo track({
    String id = videoId,
    String url = 'https://www.youtube.com/watch?v=$videoId',
    String? streamUrl,
    TrackMetadataSource metadataSource = TrackMetadataSource.youtube,
  }) {
    return TrackInfo(
      id: id,
      title: 'Never Gonna Give You Up',
      artist: 'Rick Astley',
      url: url,
      streamUrl: streamUrl,
      metadataSource: metadataSource,
    );
  }

  group('SharePlusTrackShareService', () {
    test('reports whether a track has a shareable YouTube identity', () {
      final service = SharePlusTrackShareService(gateway: _RecordingGateway());

      expect(service.canShare(track()), isTrue);
      expect(
        service.canShare(
          track(id: 'invalid', url: 'file:///tmp/local-song.mp3'),
        ),
        isFalse,
      );
    });

    for (final message in <String>[
      'Escucha “Never Gonna Give You Up” de Rick Astley:',
      'Listen to “Never Gonna Give You Up” by Rick Astley:',
    ]) {
      test('uses the localized message supplied by the UI: $message', () async {
        final gateway = _RecordingGateway();
        final service = SharePlusTrackShareService(gateway: gateway);

        await service.shareTrack(
          track(),
          message: message,
          title: 'BStream Music',
        );

        expect(gateway.callCount, 1);
        expect(
          gateway.text,
          '$message\n\nhttps://www.youtube.com/watch?v=$videoId',
        );
      });
    }

    test('uses YouTube Music for YouTube Music catalog metadata', () async {
      final gateway = _RecordingGateway();
      final service = SharePlusTrackShareService(gateway: gateway);

      await service.shareTrack(
        track(metadataSource: TrackMetadataSource.youtubeMusic),
        message: 'Listen to this song:',
        title: 'Share song',
      );

      expect(
        gateway.text,
        'Listen to this song:\n\n'
        'https://music.youtube.com/watch?v=$videoId',
      );
      expect(gateway.text, isNot(contains('bstreammusic://track/')));
      expect(gateway.text, isNot(contains('https://www.youtube.com/')));
    });

    test('uses and canonicalizes an existing YouTube Music URL', () async {
      const urlVideoId = 'M7lc1UVf-VE';
      final gateway = _RecordingGateway();
      final service = SharePlusTrackShareService(gateway: gateway);

      await service.shareTrack(
        track(
          id: videoId,
          url:
              'https://music.youtube.com/watch?feature=share&v=$urlVideoId'
              '&list=RDAMVM$urlVideoId&index=4&si=tracking',
        ),
        message: 'Listen to this song:',
        title: 'Share song',
      );

      expect(
        gateway.text,
        'Listen to this song:\n\n'
        'https://music.youtube.com/watch?v=$urlVideoId',
      );
      expect(gateway.text, isNot(contains('list=')));
      expect(gateway.text, isNot(contains('si=')));
      expect(gateway.text, isNot(contains('YouTube:')));
    });

    test('never shares the temporary stream URL', () async {
      const temporaryStreamUrl =
          'https://rr1---sn.example.googlevideo.com/videoplayback?expire=123';
      final gateway = _RecordingGateway();
      final service = SharePlusTrackShareService(gateway: gateway);

      await service.shareTrack(
        track(streamUrl: temporaryStreamUrl),
        message: 'Listen to this song:',
        title: 'Share song',
      );

      expect(gateway.text, isNot(contains(temporaryStreamUrl)));
      expect(gateway.text, isNot(contains('googlevideo.com')));
      expect(
        gateway.text,
        'Listen to this song:\n\n'
        'https://www.youtube.com/watch?v=$videoId',
      );
    });

    test('forwards title, subject, and share sheet origin', () async {
      final gateway = _RecordingGateway();
      final service = SharePlusTrackShareService(gateway: gateway);
      const origin = Rect.fromLTWH(16, 24, 48, 48);

      await service.shareTrack(
        track(),
        message: 'Listen to this song:',
        title: 'Share Never Gonna Give You Up',
        subject: 'A song for you',
        sharePositionOrigin: origin,
      );

      expect(gateway.title, 'Share Never Gonna Give You Up');
      expect(gateway.subject, 'A song for you');
      expect(gateway.sharePositionOrigin, origin);
    });

    test('throws without invoking the gateway for an unsupported track', () {
      final gateway = _RecordingGateway();
      final service = SharePlusTrackShareService(gateway: gateway);
      final unsupported = track(
        id: 'invalid',
        url: 'https://example.com/not-youtube',
        streamUrl: 'https://example.com/audio.mp3',
      );

      expect(
        () => service.shareTrack(
          unsupported,
          message: 'Listen to this song:',
          title: 'Share song',
        ),
        throwsFormatException,
      );
      expect(gateway.callCount, 0);
    });

    test('propagates gateway failures', () async {
      final service = SharePlusTrackShareService(
        gateway: _RecordingGateway(error: StateError('share unavailable')),
      );

      await expectLater(
        service.shareTrack(
          track(),
          message: 'Listen to this song:',
          title: 'Share song',
        ),
        throwsStateError,
      );
    });
  });
}

final class _RecordingGateway implements TrackShareGateway {
  _RecordingGateway({this.error});

  final Object? error;
  int callCount = 0;
  String? text;
  String? title;
  String? subject;
  Rect? sharePositionOrigin;

  @override
  Future<void> share({
    required String text,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    callCount += 1;
    this.text = text;
    this.title = title;
    this.subject = subject;
    this.sharePositionOrigin = sharePositionOrigin;
    if (error case final error?) {
      throw error;
    }
  }
}
