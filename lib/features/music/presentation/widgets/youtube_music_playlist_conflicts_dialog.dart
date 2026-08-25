import 'package:flutter/material.dart';

import '../../../../core/theme/app_dialog.dart';
import '../../../../services/youtube_music/playlist_sync/playlist_sync_models.dart';
import '../../../../services/youtube_music/playlist_sync/playlist_sync_store.dart';
import '../providers/app_strings.dart';

typedef YouTubeMusicPlaylistConflictResolver =
    Future<bool> Function(
      PlaylistSyncUnresolvedConflict conflict,
      PlaylistSyncConflictResolution resolution,
    );

class YouTubeMusicPlaylistConflictsDialog extends StatefulWidget {
  const YouTubeMusicPlaylistConflictsDialog({
    super.key,
    required this.conflicts,
    required this.strings,
    required this.onResolve,
  });

  final List<PlaylistSyncUnresolvedConflict> conflicts;
  final AppStrings strings;
  final YouTubeMusicPlaylistConflictResolver onResolve;

  @override
  State<YouTubeMusicPlaylistConflictsDialog> createState() =>
      _YouTubeMusicPlaylistConflictsDialogState();
}

class _YouTubeMusicPlaylistConflictsDialogState
    extends State<YouTubeMusicPlaylistConflictsDialog> {
  late final List<PlaylistSyncUnresolvedConflict> _conflicts =
      _oneConflictPerPlaylist(widget.conflicts);
  PlaylistSyncKey? _busyKey;

  @override
  Widget build(BuildContext context) {
    return AppAlertDialog(
      key: const Key('youtube-music-playlist-conflicts-dialog'),
      title: Text(widget.strings.resolvePlaylistSyncConflicts),
      content: SizedBox(
        width: 520,
        height: (_conflicts.length * 144 + 96).clamp(240, 520).toDouble(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.strings.playlistSyncConflictWarning),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                itemCount: _conflicts.length,
                separatorBuilder: (_, _) => const Divider(height: 20),
                itemBuilder: (context, index) {
                  final conflict = _conflicts[index];
                  final busy = _busyKey == conflict.key;
                  return Column(
                    key: ValueKey(
                      'youtube-music-conflict-${conflict.key.playlistId}',
                    ),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        conflict.playlistTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (conflict.message?.trim().isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text(
                          conflict.message!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          OutlinedButton(
                            key: ValueKey(
                              'youtube-music-conflict-keep-local-'
                              '${conflict.key.playlistId}',
                            ),
                            onPressed: busy
                                ? null
                                : () => _resolve(
                                    conflict,
                                    PlaylistSyncConflictResolution.keepLocal,
                                  ),
                            child: Text(widget.strings.keepBStreamPlaylist),
                          ),
                          if (conflict.kind !=
                              PlaylistSyncConflictKind.remoteDeleted)
                            OutlinedButton(
                              key: ValueKey(
                                'youtube-music-conflict-keep-remote-'
                                '${conflict.key.playlistId}',
                              ),
                              onPressed: busy
                                  ? null
                                  : () => _resolve(
                                      conflict,
                                      PlaylistSyncConflictResolution.keepRemote,
                                    ),
                              child: Text(
                                widget.strings.keepYouTubeMusicPlaylist,
                              ),
                            ),
                          if (busy)
                            const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busyKey == null
              ? () => Navigator.of(context).pop()
              : null,
          child: Text(widget.strings.close),
        ),
      ],
    );
  }

  Future<void> _resolve(
    PlaylistSyncUnresolvedConflict conflict,
    PlaylistSyncConflictResolution resolution,
  ) async {
    setState(() => _busyKey = conflict.key);
    var resolved = false;
    try {
      resolved = await widget.onResolve(conflict, resolution);
    } on Object {
      resolved = false;
    }
    if (!mounted) return;
    if (resolved) {
      _conflicts.removeWhere((item) => item.key == conflict.key);
      if (_conflicts.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(widget.strings.playlistConflictResolveFailed)),
        );
    }
    setState(() => _busyKey = null);
  }
}

List<PlaylistSyncUnresolvedConflict> _oneConflictPerPlaylist(
  Iterable<PlaylistSyncUnresolvedConflict> conflicts,
) {
  final unique = <PlaylistSyncKey, PlaylistSyncUnresolvedConflict>{};
  for (final conflict in conflicts) {
    // The store returns newest-first. Resolving one playlist resolves every
    // frozen row for that account/playlist pair, so render one action group.
    unique.putIfAbsent(conflict.key, () => conflict);
  }
  return List<PlaylistSyncUnresolvedConflict>.of(unique.values);
}
