/// Models used by the authenticated YouTube Music account boundary.
///
/// These types intentionally do not depend on BStream's local-library models.
/// A synchronization layer can therefore decide how remote occurrences map to
/// local tracks without losing duplicate playlist entries.
library;

enum RemotePlaylistVisibility { private, unlisted, public, unknown }

enum RemotePaginationTermination { exhausted, repeatedContinuation, pageLimit }

class RemoteAccountProfile {
  const RemoteAccountProfile({
    required this.displayName,
    this.email,
    this.handle,
    this.avatarUrl,
    this.channelId,
  });

  final String displayName;
  final String? email;
  final String? handle;
  final String? avatarUrl;
  final String? channelId;
}

class RemoteAccountChannel {
  const RemoteAccountChannel({
    required this.displayName,
    this.handle,
    this.channelId,
    this.pageId,
    this.dataSyncId,
    this.signInUrl,
    this.avatarUrl,
    this.isSelected = false,
  });

  final String displayName;
  final String? handle;
  final String? channelId;

  /// Identity token used by YouTube when switching Brand/creator identities.
  /// It is opaque and must not be interpreted by the application.
  final String? pageId;
  final String? dataSyncId;

  /// Ephemeral identity-switch URL. It must never be persisted.
  final String? signInUrl;
  final String? avatarUrl;
  final bool isSelected;
}

class RemoteGoogleAccount {
  RemoteGoogleAccount({
    required this.displayName,
    this.email,
    this.avatarUrl,
    this.isSelected = false,
    List<RemoteAccountChannel> channels = const <RemoteAccountChannel>[],
  }) : channels = List<RemoteAccountChannel>.unmodifiable(channels);

  final String displayName;
  final String? email;
  final String? avatarUrl;
  final bool isSelected;
  final List<RemoteAccountChannel> channels;
}

class RemoteAccountDirectory {
  RemoteAccountDirectory({
    List<RemoteGoogleAccount> accounts = const <RemoteGoogleAccount>[],
    List<RemoteAccountChannel> channels = const <RemoteAccountChannel>[],
  }) : accounts = List<RemoteGoogleAccount>.unmodifiable(accounts),
       channels = List<RemoteAccountChannel>.unmodifiable(channels);

  final List<RemoteGoogleAccount> accounts;
  final List<RemoteAccountChannel> channels;

  RemoteAccountChannel? get selectedChannel {
    for (final channel in channels) {
      if (channel.isSelected) {
        return channel;
      }
    }
    return null;
  }
}

class RemotePlaylistSummary {
  const RemotePlaylistSummary({
    required this.playlistId,
    required this.title,
    this.owner,
    this.thumbnailUrl,
    this.itemCount,
    this.visibility = RemotePlaylistVisibility.unknown,
    this.isEditable = false,
  });

  /// Canonical playlist identifier without YouTube's `VL` browse prefix.
  final String playlistId;
  final String title;
  final String? owner;
  final String? thumbnailUrl;
  final int? itemCount;
  final RemotePlaylistVisibility visibility;
  final bool isEditable;

  String get browseId => 'VL$playlistId';
}

class RemotePlaylistEntry {
  RemotePlaylistEntry({
    required this.position,
    required this.title,
    required List<String> artists,
    List<String?>? artistBrowseIds,
    this.videoId,
    this.setVideoId,
    this.album,
    this.duration,
    this.thumbnailUrl,
    this.isAvailable = true,
  }) : artists = List<String>.unmodifiable(artists),
       artistBrowseIds = _normalizeArtistBrowseIds(artists, artistBrowseIds);

  /// Zero-based position in the complete remote playlist snapshot.
  final int position;

  /// Playback id. It can be absent for a deleted or region-blocked row.
  final String? videoId;

  /// Per-occurrence identifier required by remove and move mutations.
  ///
  /// Two rows with the same [videoId] remain distinct because each occurrence
  /// has its own `setVideoId`. Callers must never deduplicate by [videoId].
  final String? setVideoId;
  final String title;
  final List<String> artists;
  final List<String?> artistBrowseIds;
  final String? album;
  final Duration? duration;
  final String? thumbnailUrl;
  final bool isAvailable;

  String get artist => artists.join(', ');

  /// Stable within a fetched snapshot even when YouTube omits setVideoId.
  String get occurrenceKey =>
      setVideoId ?? '${videoId ?? 'unavailable'}@$position';
}

class RemotePlaylistCollection {
  RemotePlaylistCollection({
    required List<RemotePlaylistSummary> playlists,
    required this.termination,
    required this.pagesFetched,
  }) : playlists = List<RemotePlaylistSummary>.unmodifiable(playlists);

  final List<RemotePlaylistSummary> playlists;
  final RemotePaginationTermination termination;
  final int pagesFetched;

  bool get isComplete => termination == RemotePaginationTermination.exhausted;
}

class RemotePlaylistSnapshot {
  RemotePlaylistSnapshot({
    required this.playlistId,
    required List<RemotePlaylistEntry> entries,
    required this.termination,
    required this.pagesFetched,
    this.summary,
  }) : entries = List<RemotePlaylistEntry>.unmodifiable(entries);

  final String playlistId;
  final RemotePlaylistSummary? summary;

  /// Ordered remote occurrences. Duplicate video ids are preserved.
  final List<RemotePlaylistEntry> entries;
  final RemotePaginationTermination termination;
  final int pagesFetched;

  bool get isComplete => termination == RemotePaginationTermination.exhausted;
}

sealed class YouTubeMusicMutationResult<T> {
  const YouTubeMusicMutationResult();

  bool get isSuccess => this is YouTubeMusicMutationSuccess<T>;
  bool get isAmbiguous => this is YouTubeMusicMutationAmbiguous<T>;
}

final class YouTubeMusicMutationSuccess<T>
    extends YouTubeMusicMutationResult<T> {
  const YouTubeMusicMutationSuccess(this.value);

  final T value;
}

/// The request may have reached YouTube, so automatically repeating it could
/// create duplicates or apply an edit twice. Reconcile with a fresh read first.
final class YouTubeMusicMutationAmbiguous<T>
    extends YouTubeMusicMutationResult<T> {
  const YouTubeMusicMutationAmbiguous({
    required this.operation,
    required this.reason,
    this.statusCode,
  });

  final String operation;
  final String reason;
  final int? statusCode;
}

final class YouTubeMusicMutationFailure<T>
    extends YouTubeMusicMutationResult<T> {
  const YouTubeMusicMutationFailure({
    required this.operation,
    required this.reason,
    this.statusCode,
  });

  final String operation;
  final String reason;
  final int? statusCode;
}

class RemotePlaylistCreated {
  const RemotePlaylistCreated({required this.playlistId});

  final String playlistId;
}

class RemotePlaylistMutationApplied {
  const RemotePlaylistMutationApplied();
}

List<String?> _normalizeArtistBrowseIds(
  List<String> artists,
  List<String?>? artistBrowseIds,
) {
  if (artistBrowseIds == null) {
    return List<String?>.unmodifiable(
      List<String?>.filled(artists.length, null),
    );
  }
  if (artistBrowseIds.length != artists.length) {
    throw ArgumentError.value(
      artistBrowseIds,
      'artistBrowseIds',
      'Must contain one entry for every artist.',
    );
  }
  return List<String?>.unmodifiable(artistBrowseIds);
}
