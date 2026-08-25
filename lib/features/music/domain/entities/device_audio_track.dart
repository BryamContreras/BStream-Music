import 'local_track.dart';

/// A playable audio file discovered on the device, outside BStream's library.
///
/// Device tracks are intentionally not database entities. They are converted
/// to transient [LocalTrack] values only at the playback boundary.
class DeviceAudioTrack {
  const DeviceAudioTrack({
    required this.id,
    required this.uri,
    required this.title,
    required this.folderId,
    required this.folderName,
    this.artist,
    this.album,
    this.duration,
    this.displayName,
    this.mimeType,
    this.relativePath,
    this.absolutePath,
    this.artworkSource,
  });

  final String id;
  final String uri;
  final String title;
  final String folderId;
  final String folderName;
  final String? artist;
  final String? album;
  final Duration? duration;
  final String? displayName;
  final String? mimeType;
  final String? relativePath;
  final String? absolutePath;

  /// Lazy reference to artwork embedded in the audio metadata.
  ///
  /// The reference itself is cheap to create. Its bytes are requested from
  /// the platform only when an image widget needs to paint this track.
  final String? artworkSource;

  LocalTrack toTransientLocalTrack({
    required String unknownArtist,
    DateTime? addedAt,
  }) {
    final normalizedArtist = artist?.trim();
    final resolvedArtist = normalizedArtist == null || normalizedArtist.isEmpty
        ? unknownArtist
        : normalizedArtist;
    return LocalTrack(
      id: id,
      title: title,
      artist: resolvedArtist,
      filePath: uri,
      addedAt: addedAt ?? DateTime.now(),
      duration: duration,
      album: album,
      thumbnailUrl: artworkSource,
      artists: normalizedArtist == null || normalizedArtist.isEmpty
          ? const <String>[]
          : <String>[normalizedArtist],
      isExternal: true,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DeviceAudioTrack &&
            id == other.id &&
            uri == other.uri &&
            title == other.title &&
            artist == other.artist &&
            album == other.album &&
            duration == other.duration &&
            folderId == other.folderId &&
            folderName == other.folderName &&
            relativePath == other.relativePath &&
            absolutePath == other.absolutePath &&
            artworkSource == other.artworkSource;
  }

  @override
  int get hashCode => Object.hash(
    id,
    uri,
    title,
    artist,
    album,
    duration,
    folderId,
    folderName,
    relativePath,
    absolutePath,
    artworkSource,
  );
}

class DeviceAudioFolder {
  const DeviceAudioFolder({
    required this.id,
    required this.name,
    required this.tracks,
  });

  final String id;
  final String name;
  final List<DeviceAudioTrack> tracks;

  int get songCount => tracks.length;

  Duration get knownDuration => tracks.fold(
    Duration.zero,
    (total, track) => total + (track.duration ?? Duration.zero),
  );
}
