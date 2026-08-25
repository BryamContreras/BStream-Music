import '../../features/music/domain/entities/device_audio_track.dart';

class DeviceAudioFilterOptions {
  const DeviceAudioFilterOptions({
    this.excludeWhatsAppAudio = true,
    this.excludeTelegramAudio = true,
    this.excludeAudioRecordings = true,
    this.excludeShortAudio = true,
    this.minimumDuration = const Duration(seconds: 30),
  });

  final bool excludeWhatsAppAudio;
  final bool excludeTelegramAudio;
  final bool excludeAudioRecordings;
  final bool excludeShortAudio;
  final Duration minimumDuration;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DeviceAudioFilterOptions &&
            excludeWhatsAppAudio == other.excludeWhatsAppAudio &&
            excludeTelegramAudio == other.excludeTelegramAudio &&
            excludeAudioRecordings == other.excludeAudioRecordings &&
            excludeShortAudio == other.excludeShortAudio &&
            minimumDuration == other.minimumDuration;
  }

  @override
  int get hashCode => Object.hash(
    excludeWhatsAppAudio,
    excludeTelegramAudio,
    excludeAudioRecordings,
    excludeShortAudio,
    minimumDuration,
  );
}

/// Applies the user-visible local audio filters without touching app state.
///
/// Unknown durations are kept: treating missing metadata as a short recording
/// would hide valid songs on desktop and on older Android media providers.
List<DeviceAudioTrack> filterDeviceAudioTracks(
  Iterable<DeviceAudioTrack> tracks, {
  DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
  String? bstreamRoot,
}) {
  final excludedRoot = _normalizedPath(bstreamRoot);
  final excludedRelativeRoot = _sharedStorageRelativePath(excludedRoot);
  return List<DeviceAudioTrack>.unmodifiable(
    tracks.where((track) {
      if (_belongsToRoot(track.absolutePath, excludedRoot) ||
          _belongsToRoot(track.relativePath, excludedRelativeRoot)) {
        return false;
      }
      if (options.excludeWhatsAppAudio && _isWhatsAppAudio(track)) {
        return false;
      }
      if (options.excludeTelegramAudio && _isTelegramAudio(track)) {
        return false;
      }
      if (options.excludeAudioRecordings && _isAudioRecording(track)) {
        return false;
      }
      final duration = track.duration;
      if (options.excludeShortAudio &&
          duration != null &&
          duration < options.minimumDuration) {
        return false;
      }
      return true;
    }),
  );
}

bool _isWhatsAppAudio(DeviceAudioTrack track) {
  final path = _trackPath(track);
  if (path.isEmpty) {
    return false;
  }
  return path.contains('/whatsapp/') ||
      path.contains('com.whatsapp/') ||
      path.contains('com.whatsapp.w4b/') ||
      path.contains('whatsapp audio') ||
      path.contains('whatsapp voice notes');
}

bool _isTelegramAudio(DeviceAudioTrack track) {
  final path = _trackPath(track);
  if (path.isEmpty) {
    return false;
  }
  return path.contains('/telegram/') ||
      path.contains('org.telegram.messenger/') ||
      path.contains('org.telegram.messenger.web/') ||
      path.contains('telegram audio') ||
      path.contains('telegram voice');
}

bool _isAudioRecording(DeviceAudioTrack track) {
  final path = _trackPath(track);
  if (path.isEmpty) {
    return false;
  }
  if (const <String>[
    'com.google.android.apps.recorder/',
    'com.android.soundrecorder/',
    'com.sec.android.app.voicenote/',
    'com.miui.voicerecorder/',
    'com.coloros.soundrecorder/',
    'com.oneplus.soundrecorder/',
    'com.huawei.soundrecorder/',
  ].any(path.contains)) {
    return true;
  }
  return RegExp(
    r'(?:^|/)(?:recording|recordings|recorder|voice recording|voice recordings|voice recorder|audio recording|audio recordings|audio recorder|call recording|call recordings|call recorder|sound recorder|sound_recorder|soundrecorder|voicerecorder|voicerecordings|callrecord|call_record)(?:/|$)',
  ).hasMatch(path);
}

String _trackPath(DeviceAudioTrack track) => <String?>[
  track.relativePath,
  track.absolutePath,
  track.folderName,
].whereType<String>().join('/').replaceAll('\\', '/').toLowerCase();

bool _belongsToRoot(String? candidate, String? normalizedRoot) {
  if (normalizedRoot == null) {
    return false;
  }
  final normalizedCandidate = _normalizedPath(candidate);
  if (normalizedCandidate == null) {
    return false;
  }
  return normalizedCandidate == normalizedRoot ||
      normalizedCandidate.startsWith('$normalizedRoot/');
}

String? _normalizedPath(String? value) {
  final input = value?.trim();
  if (input == null || input.isEmpty) {
    return null;
  }
  var path = input;
  if (path.toLowerCase().startsWith('file:')) {
    final uri = Uri.tryParse(path);
    if (uri != null && uri.scheme == 'file') {
      path = Uri.decodeComponent(uri.path);
      if (RegExp(r'^/[a-zA-Z]:/').hasMatch(path)) {
        path = path.substring(1);
      }
    }
  }
  path = path.replaceAll('\\', '/').replaceAll(RegExp('/+'), '/');
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path.toLowerCase();
}

String? _sharedStorageRelativePath(String? normalizedRoot) {
  if (normalizedRoot == null) {
    return null;
  }
  for (final prefix in const <String>[
    '/storage/emulated/0/',
    '/storage/self/primary/',
    '/sdcard/',
  ]) {
    if (normalizedRoot.startsWith(prefix)) {
      return normalizedRoot.substring(prefix.length);
    }
  }
  for (final prefix in const <String>['/storage/', '/mnt/media_rw/']) {
    if (!normalizedRoot.startsWith(prefix)) {
      continue;
    }
    final volumeAndPath = normalizedRoot.substring(prefix.length);
    final separator = volumeAndPath.indexOf('/');
    if (separator >= 0 && separator + 1 < volumeAndPath.length) {
      return volumeAndPath.substring(separator + 1);
    }
  }
  return null;
}
