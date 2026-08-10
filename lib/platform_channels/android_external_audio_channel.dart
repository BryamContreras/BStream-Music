import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';
import '../features/music/domain/entities/local_track.dart';

class AndroidExternalAudioChannel {
  const AndroidExternalAudioChannel({EventChannel? eventChannel})
    : _eventChannel =
          eventChannel ??
          const EventChannel(AppConstants.androidExternalAudioChannel);

  final EventChannel _eventChannel;

  Stream<ExternalAudioRequest> get requests => _eventChannel
      .receiveBroadcastStream()
      .map(ExternalAudioRequest.fromPlatformEvent);
}

class ExternalAudioRequest {
  const ExternalAudioRequest({
    required this.requestId,
    required this.selectedIndex,
    required this.tracks,
    required this.folderQueueComplete,
    required this.permissionPending,
    required this.permissionDenied,
  });

  final String requestId;
  final int selectedIndex;
  final List<ExternalAudioTrack> tracks;
  final bool folderQueueComplete;
  final bool permissionPending;
  final bool permissionDenied;

  String get queueSourceId => 'external-folder:$requestId';

  factory ExternalAudioRequest.fromPlatformEvent(Object? event) {
    if (event is! Map<Object?, Object?>) {
      throw const FormatException('Invalid external audio request.');
    }

    final requestId = _nonEmptyString(event['requestId']);
    final rawTracks = event['tracks'];
    if (requestId == null || rawTracks is! List<Object?>) {
      throw const FormatException('Incomplete external audio request.');
    }

    final tracks = rawTracks
        .map(ExternalAudioTrack.fromPlatformValue)
        .toList(growable: false);
    if (tracks.isEmpty) {
      throw const FormatException('External audio queue is empty.');
    }

    final rawIndex = event['selectedIndex'];
    final selectedIndex = rawIndex is num ? rawIndex.toInt() : 0;
    if (selectedIndex < 0 || selectedIndex >= tracks.length) {
      throw const FormatException('Invalid selected external audio index.');
    }

    return ExternalAudioRequest(
      requestId: requestId,
      selectedIndex: selectedIndex,
      tracks: List.unmodifiable(tracks),
      folderQueueComplete: event['folderQueueComplete'] == true,
      permissionPending: event['permissionPending'] == true,
      permissionDenied: event['permissionDenied'] == true,
    );
  }

  List<LocalTrack> toLocalTracks({required String unknownArtist}) {
    final addedAt = DateTime.now();
    return tracks
        .map(
          (track) => track.toLocalTrack(
            addedAt: addedAt,
            unknownArtist: unknownArtist,
          ),
        )
        .toList(growable: false);
  }
}

class ExternalAudioTrack {
  const ExternalAudioTrack({
    required this.id,
    required this.uri,
    required this.title,
    this.artist,
    this.displayName,
    this.mimeType,
    this.duration,
  });

  final String id;
  final String uri;
  final String title;
  final String? artist;
  final String? displayName;
  final String? mimeType;
  final Duration? duration;

  factory ExternalAudioTrack.fromPlatformValue(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('Invalid external audio track.');
    }

    final uri = _nonEmptyString(value['uri']);
    if (uri == null) {
      throw const FormatException('External audio URI is missing.');
    }
    final displayName = _nonEmptyString(value['displayName']);
    final title =
        _nonEmptyString(value['title']) ??
        _titleFromDisplayName(displayName) ??
        'Audio';
    final rawDuration = value['durationMs'];
    final durationMs = rawDuration is num ? rawDuration.toInt() : 0;

    return ExternalAudioTrack(
      id: _nonEmptyString(value['id']) ?? 'external:$uri',
      uri: uri,
      title: title,
      artist: _meaningfulArtist(value['artist']),
      displayName: displayName,
      mimeType: _nonEmptyString(value['mimeType']),
      duration: durationMs > 0 ? Duration(milliseconds: durationMs) : null,
    );
  }

  LocalTrack toLocalTrack({
    required DateTime addedAt,
    required String unknownArtist,
  }) {
    return LocalTrack(
      id: id,
      title: title,
      artist: artist ?? unknownArtist,
      filePath: uri,
      addedAt: addedAt,
      duration: duration,
      isExternal: true,
    );
  }
}

String? _nonEmptyString(Object? value) {
  final normalized = value?.toString().trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _meaningfulArtist(Object? value) {
  final artist = _nonEmptyString(value);
  if (artist == null || artist.toLowerCase() == '<unknown>') {
    return null;
  }
  return artist;
}

String? _titleFromDisplayName(String? displayName) {
  if (displayName == null) {
    return null;
  }
  final dot = displayName.lastIndexOf('.');
  final title = dot > 0 ? displayName.substring(0, dot) : displayName;
  return _nonEmptyString(title);
}
