import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';
import '../features/music/domain/entities/local_track.dart';

class AndroidExternalAudioChannel {
  static const _maxPendingRequests = 8;

  AndroidExternalAudioChannel({MethodChannel? methodChannel})
    : _methodChannel =
          methodChannel ??
          const MethodChannel(AppConstants.androidExternalAudioChannel) {
    _controller = StreamController<ExternalAudioRequest>.broadcast(
      onListen: _flushPending,
    );
  }

  final MethodChannel _methodChannel;
  late final StreamController<ExternalAudioRequest> _controller;
  final List<ExternalAudioRequest> _pending = <ExternalAudioRequest>[];
  bool _initialized = false;

  Stream<ExternalAudioRequest> get requests {
    if (!_initialized) {
      _initialized = true;
      unawaited(_initialize());
    }
    return _controller.stream;
  }

  Future<void> _initialize() async {
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method != 'externalAudio') {
        throw MissingPluginException('Unknown external audio method.');
      }
      _emit(ExternalAudioRequest.fromPlatformEvent(call.arguments));
      return true;
    });

    try {
      final pending = await _methodChannel.invokeListMethod<Object?>(
        'consumePendingExternalAudioEvents',
      );
      for (final event in pending ?? const <Object?>[]) {
        _emit(ExternalAudioRequest.fromPlatformEvent(event));
      }
    } on MissingPluginException {
      // This bridge exists only in the Android application.
    } catch (error, stackTrace) {
      debugPrint('Could not consume pending external audio: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _emit(ExternalAudioRequest request) {
    if (_controller.hasListener) {
      _controller.add(request);
      return;
    }
    while (_pending.length >= _maxPendingRequests) {
      _pending.removeAt(0);
    }
    _pending.add(request);
  }

  void _flushPending() {
    if (_pending.isEmpty) {
      return;
    }
    for (final request in List<ExternalAudioRequest>.of(_pending)) {
      _controller.add(request);
    }
    _pending.clear();
  }

  @visibleForTesting
  Future<void> dispose() async {
    _methodChannel.setMethodCallHandler(null);
    await _controller.close();
  }
}

final androidExternalAudioChannel = AndroidExternalAudioChannel();

class ExternalAudioRequest {
  const ExternalAudioRequest({
    required this.requestId,
    required this.selectedIndex,
    required this.tracks,
    required this.folderQueueComplete,
    required this.permissionPending,
    required this.permissionDenied,
    this.openPlayer = true,
    this.entryGeneration = 0,
  });

  final String requestId;
  final int selectedIndex;
  final List<ExternalAudioTrack> tracks;
  final bool folderQueueComplete;
  final bool permissionPending;
  final bool permissionDenied;
  final bool openPlayer;
  final int entryGeneration;

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
      openPlayer: event['openPlayer'] != false,
      entryGeneration: event['entryGeneration'] is num
          ? (event['entryGeneration'] as num).toInt()
          : 0,
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
