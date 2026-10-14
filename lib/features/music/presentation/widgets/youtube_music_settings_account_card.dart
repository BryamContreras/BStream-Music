import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dialog.dart';
import '../providers/app_strings.dart';
import '../providers/youtube_music_auth_controller.dart';
import 'youtube_music_account_avatar.dart';
import 'youtube_music_account_button.dart'
    show buildYouTubeMusicLoginPageForPlatform;
import 'youtube_music_login_disclosure_dialog.dart';

class YouTubeMusicSettingsAccountCard extends ConsumerStatefulWidget {
  const YouTubeMusicSettingsAccountCard({required this.strings, super.key});

  final AppStrings strings;

  @override
  ConsumerState<YouTubeMusicSettingsAccountCard> createState() =>
      _YouTubeMusicSettingsAccountCardState();
}

class _YouTubeMusicSettingsAccountCardState
    extends ConsumerState<YouTubeMusicSettingsAccountCard> {
  var _actionBusy = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(youtubeMusicAuthControllerProvider);
    final isRestoring = auth.phase == YouTubeMusicAuthPhase.restoring;
    final isSignedIn = auth.isAuthenticated;
    final profile = isSignedIn ? auth.profile : null;
    final secondary = profile?.handle ?? profile?.email;
    final colors = Theme.of(context).colorScheme;

    return Card(
      key: const ValueKey('settings-youtube-music-account-card'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow.withValues(alpha: 0.88),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(
          children: <Widget>[
            YouTubeMusicAccountAvatar(profile: profile, size: 88),
            const SizedBox(height: 12),
            Text(
              profile?.displayName ??
                  widget.strings.choose(
                    'Cuenta de YouTube Music',
                    'YouTube Music account',
                  ),
              key: const ValueKey('settings-youtube-music-account-name'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (secondary != null && secondary.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                secondary,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ] else if (!isSignedIn) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                widget.strings.choose(
                  'Inicia sesión para conectar tu cuenta',
                  'Sign in to connect your account',
                ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: ValueKey(
                  isSignedIn
                      ? 'settings-youtube-music-sign-out'
                      : 'settings-youtube-music-sign-in',
                ),
                onPressed: isRestoring || _actionBusy
                    ? null
                    : isSignedIn
                    ? _confirmSignOut
                    : _openSignIn,
                icon: _actionBusy || isRestoring
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        isSignedIn ? Icons.logout_rounded : Icons.login_rounded,
                      ),
                label: Text(
                  isRestoring
                      ? widget.strings.choose(
                          'Comprobando cuenta…',
                          'Checking account…',
                        )
                      : isSignedIn
                      ? widget.strings.choose('Cerrar sesión', 'Sign out')
                      : widget.strings.choose('Iniciar sesión', 'Sign in'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSignIn() async {
    setState(() => _actionBusy = true);
    try {
      final accepted = await YouTubeMusicLoginDisclosureDialog.show(
        context,
        strings: widget.strings,
      );
      if (!accepted || !mounted) return;
      final loginPage = buildYouTubeMusicLoginPageForPlatform(
        isWeb: kIsWeb,
        platform: defaultTargetPlatform,
      );
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (context) => loginPage,
          settings: const RouteSettings(name: 'youtube-music-login'),
        ),
      );
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        key: const Key('settings-youtube-music-sign-out-confirmation'),
        title: Text(widget.strings.choose('¿Cerrar sesión?', 'Sign out?')),
        content: Text(
          widget.strings.choose(
            'Se desconectará la cuenta de este dispositivo. Tu biblioteca local no se borrará.',
            'This account will be disconnected from this device. Your local library will not be deleted.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(widget.strings.cancel),
          ),
          FilledButton(
            key: const Key('settings-youtube-music-sign-out-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(widget.strings.choose('Cerrar sesión', 'Sign out')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _actionBusy = true);
    try {
      await ref.read(youtubeMusicAuthControllerProvider.notifier).logout();
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }
}
