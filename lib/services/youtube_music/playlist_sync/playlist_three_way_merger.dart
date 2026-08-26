// ignore_for_file: prefer_initializing_formals

import '../../../features/music/domain/entities/catalog_track.dart';
import 'playlist_sync_models.dart';

typedef PlaylistItemIdFactory = String Function();

/// Loss-averse three-way merge for ordered playlist occurrences.
///
/// Base occurrences are matched with local UUIDs and remote `setVideoId`s.
/// Same-video duplicates therefore remain independent. Deletion wins over a
/// reorder, additions from both sides are retained, and incompatible title or
/// order edits are surfaced instead of guessed.
class PlaylistThreeWayMerger {
  const PlaylistThreeWayMerger({required PlaylistItemIdFactory itemIdFactory})
    : _itemIdFactory = itemIdFactory;

  final PlaylistItemIdFactory _itemIdFactory;

  PlaylistMergeResult merge({
    required PlaylistSyncSnapshot? base,
    required PlaylistSyncSnapshot local,
    required PlaylistSyncSnapshot remote,
    bool ignoreTitleConflicts = false,
    bool ignoreOrderConflicts = false,
    bool matchItemsByVideoIdOnly = false,
  }) {
    if (base == null) {
      return PlaylistMergeResult.merged(_initialUnion(local, remote));
    }

    final conflicts = <PlaylistSyncConflict>[];
    final localTitleChanged = local.title != base.title;
    final remoteTitleChanged = remote.title != base.title;
    if (!ignoreTitleConflicts &&
        localTitleChanged &&
        remoteTitleChanged &&
        local.title != remote.title) {
      conflicts.add(
        const PlaylistSyncConflict(
          kind: PlaylistSyncConflictKind.title,
          message: 'El título cambió de forma distinta local y remotamente.',
        ),
      );
    }

    final baseTokens = <String>[
      for (var index = 0; index < base.items.length; index++) 'base:$index',
    ];
    final localSide = _tokenizeSide(
      base: base,
      side: local,
      prefix: 'local',
      preferLocalIds: true,
      matchItemsByVideoIdOnly: matchItemsByVideoIdOnly,
    );
    final remoteSide = _tokenizeSide(
      base: base,
      side: remote,
      prefix: 'remote',
      preferLocalIds: false,
      matchItemsByVideoIdOnly: matchItemsByVideoIdOnly,
    );
    final keptBaseTokens = baseTokens
        .where(
          (token) =>
              localSide.items.containsKey(token) &&
              remoteSide.items.containsKey(token),
        )
        .toSet();
    final baseKeptOrder = baseTokens
        .where(keptBaseTokens.contains)
        .toList(growable: false);
    final localKeptOrder = localSide.tokens
        .where(keptBaseTokens.contains)
        .toList(growable: false);
    final remoteKeptOrder = remoteSide.tokens
        .where(keptBaseTokens.contains)
        .toList(growable: false);
    final localReordered = !_sameOrder(localKeptOrder, baseKeptOrder);
    final remoteReordered = !_sameOrder(remoteKeptOrder, baseKeptOrder);
    if (!ignoreOrderConflicts &&
        localReordered &&
        remoteReordered &&
        !_sameOrder(localKeptOrder, remoteKeptOrder)) {
      conflicts.add(
        const PlaylistSyncConflict(
          kind: PlaylistSyncConflictKind.order,
          message: 'El orden cambió de forma incompatible en ambos lados.',
        ),
      );
    }
    if (conflicts.isNotEmpty) {
      return PlaylistMergeResult.conflicted(conflicts);
    }

    final localAllowed = <String>{
      ...keptBaseTokens,
      ...localSide.additionTokens,
    };
    final remoteAllowed = <String>{
      ...keptBaseTokens,
      ...remoteSide.additionTokens,
    };
    final localSequence = localSide.tokens
        .where(localAllowed.contains)
        .toList(growable: false);
    final remoteSequence = remoteSide.tokens
        .where(remoteAllowed.contains)
        .toList(growable: false);
    final primary = remoteReordered && !localReordered
        ? List<String>.of(remoteSequence)
        : List<String>.of(localSequence);
    final secondary = remoteReordered && !localReordered
        ? localSequence
        : remoteSequence;
    _injectMissing(primary, secondary);

    final mergedItems = <PlaylistSyncItem>[];
    for (final token in primary) {
      if (token.startsWith('base:')) {
        final baseIndex = int.parse(token.substring('base:'.length));
        final baseItem = base.items[baseIndex];
        final localItem = localSide.items[token]!;
        final remoteItem = remoteSide.items[token]!;
        mergedItems.add(
          remoteItem.copyWith(
            localItemId: localItem.localItemId ?? baseItem.localItemId,
            localTrackId: localItem.localTrackId ?? baseItem.localTrackId,
            videoId:
                remoteItem.videoId ?? localItem.videoId ?? baseItem.videoId,
            setVideoId: remoteItem.setVideoId ?? baseItem.setVideoId,
            track: _preferMetadata(remoteItem.track, localItem.track),
          ),
        );
      } else if (localSide.items.containsKey(token)) {
        mergedItems.add(localSide.items[token]!);
      } else {
        final remoteItem = remoteSide.items[token]!;
        mergedItems.add(remoteItem.copyWith(localItemId: _itemIdFactory()));
      }
    }
    final title = localTitleChanged ? local.title : remote.title;
    return PlaylistMergeResult.merged(
      PlaylistSyncSnapshot(
        remotePlaylistId: remote.remotePlaylistId,
        title: title,
        items: mergedItems,
        remoteRevision: remote.remoteRevision,
        isEditable: remote.isEditable,
        privacy: remote.privacy,
      ),
    );
  }

  PlaylistSyncSnapshot _initialUnion(
    PlaylistSyncSnapshot local,
    PlaylistSyncSnapshot remote,
  ) {
    final remoteMatched = <int>{};
    final merged = <PlaylistSyncItem>[];
    for (final localItem in local.items) {
      final match = _firstUnmatchedVideo(
        remote.items,
        remoteMatched,
        localItem.videoId,
      );
      if (match == null) {
        merged.add(localItem);
        continue;
      }
      remoteMatched.add(match);
      final remoteItem = remote.items[match];
      merged.add(
        remoteItem.copyWith(
          localItemId: localItem.localItemId ?? _itemIdFactory(),
          localTrackId: localItem.localTrackId,
          track: _preferMetadata(remoteItem.track, localItem.track),
        ),
      );
    }
    for (var index = 0; index < remote.items.length; index++) {
      if (!remoteMatched.contains(index)) {
        merged.add(remote.items[index].copyWith(localItemId: _itemIdFactory()));
      }
    }
    return PlaylistSyncSnapshot(
      remotePlaylistId: remote.remotePlaylistId,
      title: local.title.trim().isEmpty ? remote.title : local.title,
      items: merged,
      remoteRevision: remote.remoteRevision,
      isEditable: remote.isEditable,
      privacy: remote.privacy,
    );
  }

  _TokenizedSide _tokenizeSide({
    required PlaylistSyncSnapshot base,
    required PlaylistSyncSnapshot side,
    required String prefix,
    required bool preferLocalIds,
    required bool matchItemsByVideoIdOnly,
  }) {
    final matchedBase = <int>{};
    final tokens = <String>[];
    final items = <String, PlaylistSyncItem>{};
    final additions = <String>{};
    for (var sideIndex = 0; sideIndex < side.items.length; sideIndex++) {
      final item = side.items[sideIndex];
      final baseIndex = _matchBaseItem(
        base.items,
        matchedBase,
        item,
        preferLocalIds: preferLocalIds,
        matchItemsByVideoIdOnly: matchItemsByVideoIdOnly,
      );
      final token = baseIndex == null
          ? '$prefix:$sideIndex'
          : 'base:$baseIndex';
      if (baseIndex == null) {
        additions.add(token);
      } else {
        matchedBase.add(baseIndex);
      }
      tokens.add(token);
      items[token] = item;
    }
    return _TokenizedSide(
      tokens: tokens,
      items: items,
      additionTokens: additions,
    );
  }

  int? _matchBaseItem(
    List<PlaylistSyncItem> base,
    Set<int> matched,
    PlaylistSyncItem item, {
    required bool preferLocalIds,
    required bool matchItemsByVideoIdOnly,
  }) {
    // Liked Music is a set of videos, not an ordinary playlist. YouTube may
    // recycle/reassign setVideoId values whenever that server-ordered list is
    // rebuilt. In that mode a playable row must therefore be matched only by
    // its durable videoId; otherwise an existing downloaded item can be
    // rebound to a completely different favorite. Rows without a videoId
    // still use their occurrence identifiers because no stronger identity is
    // available for unavailable/region-blocked entries.
    if (matchItemsByVideoIdOnly && item.videoId != null) {
      return _firstUnmatchedVideo(base, matched, item.videoId);
    }
    if (preferLocalIds && item.localItemId != null) {
      for (var index = 0; index < base.length; index++) {
        if (!matched.contains(index) &&
            base[index].localItemId == item.localItemId) {
          return index;
        }
      }
    }
    if (!preferLocalIds && item.setVideoId != null) {
      for (var index = 0; index < base.length; index++) {
        if (!matched.contains(index) &&
            base[index].setVideoId == item.setVideoId) {
          return index;
        }
      }
    }
    return _firstUnmatchedVideo(base, matched, item.videoId);
  }

  int? _firstUnmatchedVideo(
    List<PlaylistSyncItem> items,
    Set<int> matched,
    String? videoId,
  ) {
    if (videoId == null) {
      return null;
    }
    for (var index = 0; index < items.length; index++) {
      if (!matched.contains(index) && items[index].videoId == videoId) {
        return index;
      }
    }
    return null;
  }

  void _injectMissing(List<String> primary, List<String> secondary) {
    for (var index = 0; index < secondary.length; index++) {
      final token = secondary[index];
      if (primary.contains(token)) {
        continue;
      }
      String? previous;
      for (var cursor = index - 1; cursor >= 0; cursor--) {
        if (primary.contains(secondary[cursor])) {
          previous = secondary[cursor];
          break;
        }
      }
      if (previous != null) {
        primary.insert(primary.indexOf(previous) + 1, token);
        continue;
      }
      String? next;
      for (var cursor = index + 1; cursor < secondary.length; cursor++) {
        if (primary.contains(secondary[cursor])) {
          next = secondary[cursor];
          break;
        }
      }
      if (next == null) {
        primary.add(token);
      } else {
        primary.insert(primary.indexOf(next), token);
      }
    }
  }

  bool _sameOrder(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  // Keep remote catalog identifiers/thumbnails, but never replace useful
  // downloaded metadata with empty remote placeholders.
  CatalogTrack _preferMetadata(CatalogTrack remote, CatalogTrack local) {
    return remote.title.trim().isEmpty ? local : remote;
  }
}

class _TokenizedSide {
  const _TokenizedSide({
    required this.tokens,
    required this.items,
    required this.additionTokens,
  });

  final List<String> tokens;
  final Map<String, PlaylistSyncItem> items;
  final Set<String> additionTokens;
}
