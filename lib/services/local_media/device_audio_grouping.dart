import '../../features/music/domain/entities/device_audio_track.dart';

List<DeviceAudioFolder> groupDeviceAudioTracksByFolder(
  Iterable<DeviceAudioTrack> tracks,
) {
  final grouped = <String, List<DeviceAudioTrack>>{};
  final names = <String, String>{};
  for (final track in tracks) {
    grouped.putIfAbsent(track.folderId, () => <DeviceAudioTrack>[]).add(track);
    names.putIfAbsent(track.folderId, () => track.folderName);
  }
  final folders = grouped.entries
      .map((entry) {
        final folderTracks = entry.value
          ..sort((left, right) {
            final title = left.title.toLowerCase().compareTo(
              right.title.toLowerCase(),
            );
            return title != 0 ? title : left.id.compareTo(right.id);
          });
        return DeviceAudioFolder(
          id: entry.key,
          name: names[entry.key] ?? 'Audio',
          tracks: List<DeviceAudioTrack>.unmodifiable(folderTracks),
        );
      })
      .toList(growable: false);
  folders.sort((left, right) {
    final name = left.name.toLowerCase().compareTo(right.name.toLowerCase());
    return name != 0 ? name : left.id.compareTo(right.id);
  });
  return List<DeviceAudioFolder>.unmodifiable(folders);
}
