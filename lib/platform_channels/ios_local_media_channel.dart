import 'package:flutter/services.dart';

import '../features/music/domain/entities/device_audio_track.dart';
import '../services/local_media/device_audio_catalog.dart';
import 'android_local_media_channel.dart' show DeviceAudioTrackPlatformModel;

/// iOS bridge for the user's locally playable Media Library audio.
///
/// Android and iOS intentionally use the same method-channel contract so the
/// Dart catalog and artwork pipeline remain platform-independent.
class IosLocalMediaChannel {
  const IosLocalMediaChannel({MethodChannel? methodChannel})
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

  Future<bool> openPermissionSettings() async {
    return await _methodChannel.invokeMethod<bool>('openPermissionSettings') ??
        false;
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

DeviceAudioPermissionStatus _permissionStatus(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'granted' => DeviceAudioPermissionStatus.granted,
    'notdetermined' ||
    'not_determined' => DeviceAudioPermissionStatus.notDetermined,
    'permanentlydenied' ||
    'permanently_denied' => DeviceAudioPermissionStatus.permanentlyDenied,
    'restricted' => DeviceAudioPermissionStatus.restricted,
    'notrequired' || 'not_required' => DeviceAudioPermissionStatus.notRequired,
    'unsupported' => DeviceAudioPermissionStatus.unsupported,
    _ => DeviceAudioPermissionStatus.denied,
  };
}
