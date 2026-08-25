import 'package:flutter/material.dart';

import '../../../../core/theme/app_dialog.dart';
import '../../../../services/youtube_music/auth/youtube_music_auth_models.dart';
import '../providers/app_strings.dart';
import 'youtube_music_account_avatar.dart';

class YouTubeMusicAccountDialog extends StatelessWidget {
  const YouTubeMusicAccountDialog({
    super.key,
    required this.profile,
    required this.onLogout,
    this.onChangeAccount,
    this.onSyncNow,
    this.onResolveConflicts,
    this.strings,
  });

  final YouTubeMusicAccountProfile profile;
  final Future<void> Function() onLogout;
  final VoidCallback? onChangeAccount;
  final Future<void> Function()? onSyncNow;
  final Future<void> Function()? onResolveConflicts;
  final AppStrings? strings;

  @override
  Widget build(BuildContext context) {
    final text = strings ?? const AppStrings(AppLanguage.spanish);
    final secondary = profile.email ?? profile.handle;
    return AppAlertDialog(
      key: const Key('youtube-music-account-dialog'),
      title: Text(text.youtubeMusicAccount),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            YouTubeMusicAccountAvatar(profile: profile, size: 72),
            const SizedBox(height: 12),
            Text(
              profile.displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (secondary != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                secondary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            Text(
              text.choose(
                'La sesión se conserva cifrada únicamente en este dispositivo.',
                'The session is stored encrypted only on this device.',
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        if (onSyncNow != null)
          TextButton.icon(
            key: const Key('youtube-music-account-sync'),
            onPressed: () async {
              Navigator.of(context).pop();
              await onSyncNow!();
            },
            icon: const Icon(Icons.sync),
            label: Text(text.syncNow),
          ),
        if (onResolveConflicts != null)
          TextButton.icon(
            key: const Key('youtube-music-account-conflicts'),
            onPressed: () async {
              Navigator.of(context).pop();
              await onResolveConflicts!();
            },
            icon: const Icon(Icons.rule_folder_outlined),
            label: Text(text.resolvePlaylistSyncConflicts),
          ),
        if (onChangeAccount != null)
          TextButton(
            key: const Key('youtube-music-account-change'),
            onPressed: () {
              Navigator.of(context).pop();
              onChangeAccount!();
            },
            child: Text(text.switchYouTubeChannel),
          ),
        TextButton(
          key: const Key('youtube-music-account-logout'),
          onPressed: () => _confirmLogout(context),
          child: Text(text.disconnectYouTubeMusic),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(text.choose('Listo', 'Done')),
        ),
      ],
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final text = strings ?? const AppStrings(AppLanguage.spanish);
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        key: const Key('youtube-music-logout-confirmation'),
        title: Text(text.choose('¿Cerrar sesión?', 'Sign out?')),
        content: Text(
          text.choose(
            'Se eliminará la sesión cifrada de YouTube Music de este '
                'dispositivo. Tu biblioteca local no se borrará.',
            'The encrypted YouTube Music session will be removed from this '
                'device. Your local library will not be deleted.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(text.cancel),
          ),
          FilledButton(
            key: const Key('youtube-music-logout-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(text.disconnectYouTubeMusic),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    Navigator.of(context).pop();
    await onLogout();
  }
}
