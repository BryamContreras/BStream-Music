import 'package:flutter/material.dart';

import '../../../../core/theme/app_dialog.dart';
import '../providers/app_strings.dart';

class YouTubeMusicPlaylistSyncConsentDialog extends StatelessWidget {
  const YouTubeMusicPlaylistSyncConsentDialog({
    super.key,
    required this.strings,
    this.localPlaylistCount,
  });

  final AppStrings strings;
  final int? localPlaylistCount;

  static Future<bool> show(
    BuildContext context, {
    required AppStrings strings,
    int? localPlaylistCount,
  }) async {
    final accepted = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => YouTubeMusicPlaylistSyncConsentDialog(
        strings: strings,
        localPlaylistCount: localPlaylistCount,
      ),
    );
    return accepted ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AppAlertDialog(
        key: const Key('youtube-music-playlist-sync-consent'),
        icon: const Icon(Icons.cloud_sync_outlined),
        title: Text(strings.playlistSyncConsentTitle),
        content: SingleChildScrollView(
          child: Text(strings.playlistSyncConsentBody(localPlaylistCount)),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('youtube-music-playlist-sync-not-now'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.notNow),
          ),
          FilledButton(
            key: const Key('youtube-music-playlist-sync-accept'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.keepAndSync),
          ),
        ],
      ),
    );
  }
}
