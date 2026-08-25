import 'package:flutter/services.dart';

import '../core/utils/image_source.dart';
import '../features/music/domain/entities/device_audio_track.dart';
import '../services/local_media/device_audio_catalog.dart';

class AndroidLocalMediaChannel {
  const AndroidLocalMediaChannel({MethodChannel? methodChannel})
    : _methodChannel =
          methodChannel ?? const MethodChannel('bstream_music/local_audio');

  final MethodChannel _methodChannel;

  Future<DeviceAudioPermissionStatus> permissionStatus() async {
    final status = await _methodChannel.invokeMethod<String>(
      'permissionStatus',
    );
    return _permissionStatus(status);
  }

  Future<DeviceAudioPermissionStatus> requestPermission() async {
    final status = await _methodChannel.invokeMethod<String>(
      'requestPermission',
    );
    return _permissionStatus(status);
  }

  Future<List<DeviceAudioTrack>> queryTracks() async {
    final payload = await _methodChannel.invokeListMethod<Object?>(
      'queryTracks',
    );
    if (payload == null) {
      return const <DeviceAudioTrack>[];
    }
    return List<DeviceAudioTrack>.unmodifiable(
      payload.map(DeviceAudioTrackPlatformModel.fromPlatformValue),
    );
  }

  /// Resolves embedded artwork only for a track that is currently rendered.
  ///
  /// Android returns a bounded encoded image, not the original full-size
  /// metadata blob, so MethodChannel traffic and decoded memory stay bounded.
  Future<Uint8List?> loadArtwork({
    required String audioUri,
    required int targetWidth,
  }) {
    return _methodChannel.invokeMethod<Uint8List>(
      'loadArtwork',
      <String, Object>{
        'audioUri': audioUri,
        'targetWidth': targetWidth.clamp(32, 1280),
      },
    );
  }
}

class DeviceAudioTrackPlatformModel {
  const DeviceAudioTrackPlatformModel._();

  static DeviceAudioTrack fromPlatformValue(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('Invalid device audio track.');
    }
    final uri = _nonEmptyString(value['uri']);
    if (uri == null) {
      throw const FormatException('Device audio URI is missing.');
    }
    final displayName = _nonEmptyString(value['displayName']);
    final title =
        _nonEmptyString(value['title']) ??
        _titleFromDisplayName(displayName) ??
        'Audio';
    final relativePath = _nonEmptyString(value['relativePath']);
    final absolutePath = _nonEmptyString(value['absolutePath']);
    final folderName =
        _nonEmptyString(value['folderName']) ??
        _folderName(relativePath ?? absolutePath) ??
        'Audio';
    final folderId =
        _nonEmptyString(value['folderId']) ??
        'folder:${(relativePath ?? absolutePath ?? folderName).toLowerCase()}';
    final rawDuration = value['durationMs'];
    final durationMs = rawDuration is num ? rawDuration.toInt() : null;
    return DeviceAudioTrack(
      id: _nonEmptyString(value['id']) ?? 'device:$uri',
      uri: uri,
      title: title,
      artist: _meaningfulMetadata(value['artist']),
      album: _meaningfulMetadata(value['album']),
      duration: durationMs != null && durationMs > 0
          ? Duration(milliseconds: durationMs)
          : null,
      displayName: displayName,
      mimeType: _nonEmptyString(value['mimeType']),
      relativePath: relativePath,
      absolutePath: absolutePath,
      artworkSource: deviceAudioArtworkSourceForUri(uri),
      folderId: folderId,
      folderName: folderName,
    );
  }
}

DeviceAudioPermissionStatus _permissionStatus(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'granted' => DeviceAudioPermissionStatus.granted,
    'notrequired' || 'not_required' => DeviceAudioPermissionStatus.notRequired,
    'unsupported' => DeviceAudioPermissionStatus.unsupported,
    _ => DeviceAudioPermissionStatus.denied,
  };
}

String? _nonEmptyString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String? _meaningfulMetadata(Object? value) {
  final text = _nonEmptyString(value);
  if (text == null || text.toLowerCase() == '<unknown>') {
    return null;
  }
  return text;
}

String? _titleFromDisplayName(String? displayName) {
  if (displayName == null) {
    return null;
  }
  final dot = displayName.lastIndexOf('.');
  return _nonEmptyString(dot > 0 ? displayName.substring(0, dot) : displayName);
}

String? _folderName(String? path) {
  if (path == null) {
    return null;
  }
  final normalized = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  return _nonEmptyString(normalized.substring(normalized.lastIndexOf('/') + 1));
}
