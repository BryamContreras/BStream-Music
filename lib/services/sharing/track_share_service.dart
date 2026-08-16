import 'dart:ui';

import 'package:share_plus/share_plus.dart';

import '../../features/music/domain/entities/track_info.dart';
import 'bstream_track_link.dart';

abstract interface class TrackShareService {
  bool canShare(TrackInfo track);

  Future<void> shareTrack(
    TrackInfo track, {
    required String message,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  });
}

abstract interface class TrackShareGateway {
  Future<void> share({
    required String text,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  });
}

class SharePlusTrackShareGateway implements TrackShareGateway {
  const SharePlusTrackShareGateway();

  @override
  Future<void> share({
    required String text,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    await SharePlus.instance.share(
      ShareParams(
        text: text,
        title: title,
        subject: subject,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}

class SharePlusTrackShareService implements TrackShareService {
  const SharePlusTrackShareService({
    this.codec = const BStreamTrackLinkCodec(),
    this.gateway = const SharePlusTrackShareGateway(),
  });

  final BStreamTrackLinkCodec codec;
  final TrackShareGateway gateway;

  @override
  bool canShare(TrackInfo track) => codec.tryFromTrack(track) != null;

  @override
  Future<void> shareTrack(
    TrackInfo track, {
    required String message,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) {
    final link = codec.fromTrack(track);
    final normalizedMessage = message.trim();
    final text = <String>[
      if (normalizedMessage.isNotEmpty) normalizedMessage,
      link.appUri.toString(),
      'YouTube: ${link.youtubeFallbackUri}',
    ].join('\n\n');
    return gateway.share(
      text: text,
      title: title,
      subject: subject,
      sharePositionOrigin: sharePositionOrigin,
    );
  }
}
