import 'dart:ui';

import 'package:bstream_music/services/sharing/track_share_service.dart';
import 'package:bstream_music/services/sharing/youtube_music_playlist_share_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SharePlusYouTubeMusicPlaylistShareService', () {
    test('reports whether the remote identity and name are shareable', () {
      final service = SharePlusYouTubeMusicPlaylistShareService(
        gateway: _RecordingGateway(),
      );

      expect(
        service.canShare(
          remotePlaylistId: 'PL1234567890abcdef',
          playlistName: 'Viaje',
        ),
        isTrue,
      );
      expect(
        service.canShare(
          remotePlaylistId: 'VLPL1234567890abcdef',
          playlistName: 'Viaje',
        ),
        isTrue,
      );
      expect(
        service.canShare(remotePlaylistId: 'PL invalid', playlistName: 'Viaje'),
        isFalse,
      );
      expect(
        service.canShare(
          remotePlaylistId: 'PL1234567890abcdef',
          playlistName: '   ',
        ),
        isFalse,
      );
    });

    test('shares a canonical YouTube Music URL and the real name', () async {
      final gateway = _RecordingGateway();
      final service = SharePlusYouTubeMusicPlaylistShareService(
        gateway: gateway,
      );

      await service.sharePlaylist(
        remotePlaylistId: 'PL1234567890abcdef',
        playlistName: 'Viaje de verano',
        message: 'Escucha esta playlist.',
        title: 'Compartir playlist',
      );

      expect(gateway.callCount, 1);
      expect(gateway.title, 'Compartir playlist: Viaje de verano');
      expect(
        gateway.text,
        'Escucha esta playlist.\n'
        'Viaje de verano\n\n'
        'https://music.youtube.com/playlist?list=PL1234567890abcdef',
      );
      expect(gateway.text, isNot(contains('VLPL')));
    });

    test('normalizes a VL browse id without duplicating the name', () async {
      final gateway = _RecordingGateway();
      final service = SharePlusYouTubeMusicPlaylistShareService(
        gateway: gateway,
      );

      await service.sharePlaylist(
        remotePlaylistId: 'VLPL1234567890abcdef',
        playlistName: 'Viaje de verano',
        message: 'Escucha "Viaje de verano" en YouTube Music.',
        title: 'Compartir Viaje de verano',
      );

      expect(gateway.title, 'Compartir Viaje de verano');
      expect(
        gateway.text,
        'Escucha "Viaje de verano" en YouTube Music.\n\n'
        'https://music.youtube.com/playlist?list=PL1234567890abcdef',
      );
      expect(RegExp('Viaje de verano').allMatches(gateway.text!).length, 1);
    });

    test('forwards subject and share sheet origin', () async {
      final gateway = _RecordingGateway();
      final service = SharePlusYouTubeMusicPlaylistShareService(
        gateway: gateway,
      );
      const origin = Rect.fromLTWH(12, 20, 48, 48);

      await service.sharePlaylist(
        remotePlaylistId: 'PL1234567890abcdef',
        playlistName: 'Favoritas del viaje',
        message: '',
        title: '',
        subject: 'Playlist para el viaje',
        sharePositionOrigin: origin,
      );

      expect(gateway.text, startsWith('Favoritas del viaje\n\n'));
      expect(gateway.title, 'Favoritas del viaje');
      expect(gateway.subject, 'Playlist para el viaje');
      expect(gateway.sharePositionOrigin, origin);
    });

    test('rejects invalid ids without invoking the gateway', () {
      final gateway = _RecordingGateway();
      final service = SharePlusYouTubeMusicPlaylistShareService(
        gateway: gateway,
      );

      expect(
        () => service.sharePlaylist(
          remotePlaylistId: 'https://music.youtube.com/playlist?list=PL123',
          playlistName: 'Viaje',
          message: 'Escucha esta playlist.',
          title: 'Compartir playlist',
        ),
        throwsFormatException,
      );
      expect(gateway.callCount, 0);
    });

    test('propagates gateway failures', () async {
      final service = SharePlusYouTubeMusicPlaylistShareService(
        gateway: _RecordingGateway(error: StateError('share unavailable')),
      );

      await expectLater(
        service.sharePlaylist(
          remotePlaylistId: 'PL1234567890abcdef',
          playlistName: 'Viaje',
          message: 'Escucha esta playlist.',
          title: 'Compartir playlist',
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
