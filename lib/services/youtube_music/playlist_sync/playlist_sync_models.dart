import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../features/music/domain/entities/catalog_track.dart';

enum PlaylistSyncMode { manual, automatic }

enum PlaylistSyncTrigger { manual, automatic, localMutation, appStart }

enum PlaylistSyncIntentStatus { pending, ambiguous, conflict }

enum RemoteMutationStatus { acknowledged, ambiguous, rejected }

enum PlaylistSyncDisposition {
  noChanges,
  synchronized,
  deferred,
  conflict,
  remoteDeleted,
  localDeleted,
}

enum PlaylistSyncConflictKind {
  title,
  order,
  ambiguousMutation,
  remoteDeleted,
  localDeleted,
  remoteNotEditable,
}

class PlaylistSyncKey {
  const PlaylistSyncKey({required this.accountKey, required this.playlistId});

  final String accountKey;
  final String playlistId;

  @override
  bool operator ==(Object other) =>
      other is PlaylistSyncKey &&
      accountKey == other.accountKey &&
      playlistId == other.playlistId;

  @override
  int get hashCode => Object.hash(accountKey, playlistId);
}

class PlaylistSyncItem {
  const PlaylistSyncItem({
    required this.track,
    this.localItemId,
    this.localTrackId,
    this.videoId,
    this.setVideoId,
  });

  final String? localItemId;
  final String? localTrackId;
  final String? videoId;
  final String? setVideoId;
  final CatalogTrack track;

  String get occurrenceIdentity =>
      setVideoId ?? localItemId ?? '${videoId ?? track.key}:unbound';

  PlaylistSyncItem copyWith({
    Object? localItemId = _unset,
    Object? localTrackId = _unset,
    Object? videoId = _unset,
    Object? setVideoId = _unset,
    CatalogTrack? track,
  }) {
    return PlaylistSyncItem(
      localItemId: identical(localItemId, _unset)
          ? this.localItemId
          : localItemId as String?,
      localTrackId: identical(localTrackId, _unset)
          ? this.localTrackId
          : localTrackId as String?,
      videoId: identical(videoId, _unset) ? this.videoId : videoId as String?,
      setVideoId: identical(setVideoId, _unset)
          ? this.setVideoId
          : setVideoId as String?,
      track: track ?? this.track,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'localItemId': localItemId,
    'localTrackId': localTrackId,
    'videoId': videoId,
    'setVideoId': setVideoId,
    'track': <String, Object?>{
      'key': track.key,
      'provider': track.provider.name,
      'providerId': track.providerId,
      'title': track.title,
      'artists': track.artists,
      'artistBrowseIds': track.artistBrowseIds,
      'album': track.album,
      'durationMs': track.duration?.inMilliseconds,
      'thumbnailUrl': track.thumbnailUrl,
      'sourceUrl': track.sourceUrl,
    },
  };

  factory PlaylistSyncItem.fromJson(Map<String, Object?> json) {
    final rawTrack = Map<String, Object?>.from(json['track']! as Map);
    final providerName = rawTrack['provider']?.toString();
    final provider = CatalogProvider.values.firstWhere(
      (candidate) => candidate.name == providerName,
      orElse: () => CatalogProvider.legacy,
    );
    final durationMs = _integer(rawTrack['durationMs']);
    return PlaylistSyncItem(
      localItemId: _text(json['localItemId']),
      localTrackId: _text(json['localTrackId']),
      videoId: _text(json['videoId']),
      setVideoId: _text(json['setVideoId']),
      track: CatalogTrack(
        key: rawTrack['key']!.toString(),
        provider: provider,
        providerId: rawTrack['providerId']!.toString(),
        title: rawTrack['title']?.toString() ?? '',
        artists: _stringList(rawTrack['artists']),
        artistBrowseIds: _nullableStringList(rawTrack['artistBrowseIds']),
        album: _text(rawTrack['album']),
        duration: durationMs == null
            ? null
            : Duration(milliseconds: durationMs),
        thumbnailUrl: _text(rawTrack['thumbnailUrl']),
        sourceUrl: _text(rawTrack['sourceUrl']),
      ),
    );
  }
}

class PlaylistSyncSnapshot {
  PlaylistSyncSnapshot({
    required this.title,
    required Iterable<PlaylistSyncItem> items,
    this.remotePlaylistId,
    this.remoteRevision,
    this.isEditable = true,
    this.privacy,
  }) : items = List<PlaylistSyncItem>.unmodifiable(items);

  final String? remotePlaylistId;
  final String title;
  final List<PlaylistSyncItem> items;
  final String? remoteRevision;
  final bool isEditable;
  final String? privacy;

  /// Content that can actually be represented by YouTube Music.
  PlaylistSyncSnapshot get remoteProjection => PlaylistSyncSnapshot(
    remotePlaylistId: remotePlaylistId,
    title: title,
    items: items.where((item) => item.videoId != null),
    remoteRevision: remoteRevision,
    isEditable: isEditable,
    privacy: privacy,
  );

  String get semanticHash {
    final canonical = <String, Object?>{
      'title': title.trim(),
      'videoIds': items
          .where((item) => item.videoId != null)
          .map((item) => item.videoId)
          .toList(growable: false),
    };
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  /// Optimistic remote revision. `setVideoId` participates when no server
  /// revision is available so same-video duplicates remain distinguishable.
  String get revisionToken {
    final supplied = remoteRevision?.trim();
    if (supplied != null && supplied.isNotEmpty) {
      return supplied;
    }
    final canonical = <String, Object?>{
      'title': title.trim(),
      'items': items
          .where((item) => item.videoId != null)
          .map(
            (item) => <String, Object?>{
              'videoId': item.videoId,
              'setVideoId': item.setVideoId,
            },
          )
          .toList(growable: false),
    };
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  bool semanticallyEquals(PlaylistSyncSnapshot other) =>
      semanticHash == other.semanticHash;

  Map<String, Object?> toJson() => <String, Object?>{
    'remotePlaylistId': remotePlaylistId,
    'title': title,
    'items': items.map((item) => item.toJson()).toList(growable: false),
    'remoteRevision': remoteRevision,
    'isEditable': isEditable,
    'privacy': privacy,
  };

  String encode() => jsonEncode(toJson());

  factory PlaylistSyncSnapshot.fromJson(Map<String, Object?> json) {
    final rawItems = json['items'];
    return PlaylistSyncSnapshot(
      remotePlaylistId: _text(json['remotePlaylistId']),
      title: json['title']?.toString() ?? '',
      items: rawItems is List
          ? rawItems.whereType<Map>().map(
              (item) =>
                  PlaylistSyncItem.fromJson(Map<String, Object?>.from(item)),
            )
          : const <PlaylistSyncItem>[],
      remoteRevision: _text(json['remoteRevision']),
      isEditable: _boolean(json['isEditable'], fallback: true),
      privacy: _text(json['privacy']),
    );
  }

  factory PlaylistSyncSnapshot.decode(String encoded) {
    return PlaylistSyncSnapshot.fromJson(
      Map<String, Object?>.from(jsonDecode(encoded) as Map),
    );
  }
}

class PlaylistSyncBinding {
  const PlaylistSyncBinding({
    required this.key,
    required this.mode,
    required this.localRevisionAtBase,
    required this.createdAt,
    required this.updatedAt,
    this.remotePlaylistId,
    this.remoteBrowseId,
    this.isEditable = true,
    this.privacy,
    this.baseTitle,
    this.baseSnapshotHash,
    this.remoteRevision,
    this.lastSyncedAt,
    this.lastRemoteSeenAt,
    this.remoteDeleteRequestedAt,
  });

  final PlaylistSyncKey key;
  final String? remotePlaylistId;
  final String? remoteBrowseId;
  final PlaylistSyncMode mode;
  final bool isEditable;
  final String? privacy;
  final String? baseTitle;
  final String? baseSnapshotHash;
  final String? remoteRevision;
  final int localRevisionAtBase;
  final DateTime? lastSyncedAt;
  final DateTime? lastRemoteSeenAt;
  final DateTime? remoteDeleteRequestedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  PlaylistSyncBinding copyWith({
    Object? remotePlaylistId = _unset,
    Object? remoteBrowseId = _unset,
    PlaylistSyncMode? mode,
    bool? isEditable,
    Object? privacy = _unset,
    Object? baseTitle = _unset,
    Object? baseSnapshotHash = _unset,
    Object? remoteRevision = _unset,
    int? localRevisionAtBase,
    Object? lastSyncedAt = _unset,
    Object? lastRemoteSeenAt = _unset,
    Object? remoteDeleteRequestedAt = _unset,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return PlaylistSyncBinding(
      key: key,
      remotePlaylistId: identical(remotePlaylistId, _unset)
          ? this.remotePlaylistId
          : remotePlaylistId as String?,
      remoteBrowseId: identical(remoteBrowseId, _unset)
          ? this.remoteBrowseId
          : remoteBrowseId as String?,
      mode: mode ?? this.mode,
      isEditable: isEditable ?? this.isEditable,
      privacy: identical(privacy, _unset) ? this.privacy : privacy as String?,
      baseTitle: identical(baseTitle, _unset)
          ? this.baseTitle
          : baseTitle as String?,
      baseSnapshotHash: identical(baseSnapshotHash, _unset)
          ? this.baseSnapshotHash
          : baseSnapshotHash as String?,
      remoteRevision: identical(remoteRevision, _unset)
          ? this.remoteRevision
          : remoteRevision as String?,
      localRevisionAtBase: localRevisionAtBase ?? this.localRevisionAtBase,
      lastSyncedAt: identical(lastSyncedAt, _unset)
          ? this.lastSyncedAt
          : lastSyncedAt as DateTime?,
      lastRemoteSeenAt: identical(lastRemoteSeenAt, _unset)
          ? this.lastRemoteSeenAt
          : lastRemoteSeenAt as DateTime?,
      remoteDeleteRequestedAt: identical(remoteDeleteRequestedAt, _unset)
          ? this.remoteDeleteRequestedAt
          : remoteDeleteRequestedAt as DateTime?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class PlaylistSyncIntent {
  const PlaylistSyncIntent({
    required this.key,
    required this.requestedLocalRevision,
    required this.reason,
    required this.status,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.desiredSnapshot,
    this.desiredSnapshotHash,
    this.mutationToken,
    this.nextAttemptAt,
    this.lastError,
  });

  final PlaylistSyncKey key;
  final int requestedLocalRevision;
  final String reason;
  final PlaylistSyncIntentStatus status;
  final PlaylistSyncSnapshot? desiredSnapshot;
  final String? desiredSnapshotHash;
  final String? mutationToken;
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class PlaylistSyncWork {
  const PlaylistSyncWork({
    required this.binding,
    required this.local,
    required this.localRevision,
    required this.localDeleted,
    this.base,
    this.intent,
  });

  final PlaylistSyncBinding binding;
  final PlaylistSyncSnapshot? base;
  final PlaylistSyncSnapshot local;
  final int localRevision;
  final bool localDeleted;
  final PlaylistSyncIntent? intent;
}

class RemoteMutationReceipt {
  const RemoteMutationReceipt({
    required this.status,
    this.remotePlaylistId,
    this.remoteRevision,
    this.message,
  });

  final RemoteMutationStatus status;
  final String? remotePlaylistId;
  final String? remoteRevision;
  final String? message;
}

class PlaylistSyncConflict {
  const PlaylistSyncConflict({required this.kind, required this.message});

  final PlaylistSyncConflictKind kind;
  final String message;
}

class PlaylistMergeResult {
  PlaylistMergeResult.merged(this.snapshot) : conflicts = const [];

  PlaylistMergeResult.conflicted(Iterable<PlaylistSyncConflict> conflicts)
    : snapshot = null,
      conflicts = List<PlaylistSyncConflict>.unmodifiable(conflicts);

  final PlaylistSyncSnapshot? snapshot;
  final List<PlaylistSyncConflict> conflicts;

  bool get hasConflicts => conflicts.isNotEmpty;
}

class PlaylistSyncResult {
  const PlaylistSyncResult({
    required this.disposition,
    this.message,
    this.conflicts = const <PlaylistSyncConflict>[],
  });

  final PlaylistSyncDisposition disposition;
  final String? message;
  final List<PlaylistSyncConflict> conflicts;
}

const Object _unset = Object();

String? _text(Object? value) {
  final normalized = value?.toString().trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

int? _integer(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value');

bool _boolean(Object? value, {required bool fallback}) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  return fallback;
}

List<String> _stringList(Object? value) => value is List
    ? value.map((item) => item.toString()).toList(growable: false)
    : const <String>[];

List<String?> _nullableStringList(Object? value) => value is List
    ? value.map((item) => item?.toString()).toList(growable: false)
    : const <String?>[];
