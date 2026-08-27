import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dialog.dart';
import '../pages/desktop_youtube_music_login_page.dart';
import '../pages/youtube_music_login_page.dart';
import '../providers/app_strings.dart';
import '../providers/music_providers.dart'
    show
        YouTubeMusicPlaylistSyncState,
        playlistsControllerProvider,
        youtubeMusicPlaylistSyncControllerProvider;
import '../providers/youtube_music_auth_controller.dart';
import 'youtube_music_account_avatar.dart';
import 'youtube_music_account_dialog.dart';
import 'youtube_music_auth_strings.dart';
import 'youtube_music_login_disclosure_dialog.dart';
import 'youtube_music_playlist_conflicts_dialog.dart';
import 'youtube_music_playlist_sync_consent_dialog.dart';

typedef YouTubeMusicAccountButtonAction =
    Future<void> Function(
      BuildContext context,
      WidgetRef ref,
      YouTubeMusicAuthState state,
    );

@visibleForTesting
Widget buildYouTubeMusicLoginPageForPlatform({
  required bool isWeb,
  required TargetPlatform platform,
  DesktopYouTubeMusicWebAuthPortFactory? desktopWebAuthPortFactory,
}) {
  final mechanism = resolveYouTubeMusicLoginMechanism(
    isWeb: isWeb,
    platform: platform,
  );
  return switch (mechanism) {
    YouTubeMusicLoginMechanism.desktopBrowser => DesktopYouTubeMusicLoginPage(
      webAuthPortFactory: desktopWebAuthPortFactory,
    ),
    YouTubeMusicLoginMechanism.embeddedWebView ||
    YouTubeMusicLoginMechanism.unsupported => const YouTubeMusicLoginPage(),
  };
}

/// Drop-in Home action. Without [onPressed], it owns disclosure, login,
/// account details and logout; callers may override navigation while keeping
/// the same safe avatar/state rendering.
class YouTubeMusicAccountButton extends ConsumerStatefulWidget {
  const YouTubeMusicAccountButton({super.key, this.onPressed, this.strings});

  final YouTubeMusicAccountButtonAction? onPressed;
  final AppStrings? strings;

  @override
  ConsumerState<YouTubeMusicAccountButton> createState() =>
      _YouTubeMusicAccountButtonState();
}

class _YouTubeMusicAccountButtonState
    extends ConsumerState<YouTubeMusicAccountButton> {
  String? _scheduledConsentAccountKey;
  var _consentDialogOpen = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(youtubeMusicAuthControllerProvider);
    final playlistSync = ref.watch(youtubeMusicPlaylistSyncControllerProvider);
    final text = resolveYouTubeMusicAppStrings(context, widget.strings);
    _scheduleConsentPrompt(playlistSync, text);
    final isRestoring = state.phase == YouTubeMusicAuthPhase.restoring;
    final tooltip = state.isAuthenticated
        ? text.youtubeMusicAccount
        : isRestoring
        ? text.choose('Comprobando cuenta', 'Checking account')
        : text.signInToYouTubeMusic;
    return Semantics(
      button: true,
      label: tooltip,
      child: IconButton(
        key: const Key('home-youtube-music-account'),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        onPressed: isRestoring
            ? null
            : () async {
                if (widget.onPressed != null) {
                  await widget.onPressed!(context, ref, state);
                } else {
                  await _openDefaultAccountFlow(state, text);
                }
              },
        icon: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            YouTubeMusicAccountAvatar(profile: state.profile, size: 30),
            if (isRestoring || playlistSync.isSyncing)
              const SizedBox.square(
                dimension: 38,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDefaultAccountFlow(
    YouTubeMusicAuthState state,
    AppStrings strings,
  ) async {
    final profile = state.profile;
    if (state.isAuthenticated && profile != null) {
      await showAppDialog<void>(
        context: context,
        builder: (dialogContext) => YouTubeMusicAccountDialog(
          profile: profile,
          strings: strings,
          onSyncNow: () => _syncNow(strings),
          onLogout: () =>
              ref.read(youtubeMusicAuthControllerProvider.notifier).logout(),
          onResolveConflicts: () =>
              _openPlaylistConflicts(context, ref, strings),
          onChangeAccount: () {
            unawaited(_openLogin(strings));
          },
        ),
      );
      return;
    }
    await _openLogin(strings);
  }

  Future<void> _openLogin(AppStrings strings) async {
    final accepted = await YouTubeMusicLoginDisclosureDialog.show(
      context,
      strings: strings,
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
    if (!mounted) return;
    final syncState = ref.read(youtubeMusicPlaylistSyncControllerProvider);
    if (syncState.shouldPromptForConsent) {
      _scheduledConsentAccountKey = null;
      _scheduleConsentPrompt(syncState, strings);
    }
  }

  void _scheduleConsentPrompt(
    YouTubeMusicPlaylistSyncState syncState,
    AppStrings strings,
  ) {
    final accountKey = syncState.consentAccountKey;
    if (!syncState.shouldPromptForConsent || accountKey == null) {
      _scheduledConsentAccountKey = null;
      return;
    }
    if (_consentDialogOpen || _scheduledConsentAccountKey == accountKey) {
      return;
    }
    _scheduledConsentAccountKey = accountKey;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent == false) {
        _scheduledConsentAccountKey = null;
        return;
      }
      await _showConsentPrompt(accountKey, strings);
    });
  }

  Future<bool> _showConsentPrompt(String accountKey, AppStrings strings) async {
    if (_consentDialogOpen || !mounted) return false;
    final authState = ref.read(youtubeMusicAuthControllerProvider);
    final syncState = ref.read(youtubeMusicPlaylistSyncControllerProvider);
    if (!authState.isAuthenticated ||
        authState.profile?.accountKey.trim() != accountKey ||
        !syncState.requiresConsent ||
        syncState.consentAccountKey != accountKey) {
      return false;
    }

    _consentDialogOpen = true;
    final controller = ref.read(
      youtubeMusicPlaylistSyncControllerProvider.notifier,
    );
    controller.markConsentPromptPresented(accountKey);
    try {
      final playlists = ref.read(playlistsControllerProvider).value;
      final localPlaylistCount = playlists
          ?.where((playlist) => !playlist.isFavorites)
          .length;
      final accepted = await YouTubeMusicPlaylistSyncConsentDialog.show(
        context,
        strings: strings,
        localPlaylistCount: localPlaylistCount,
      );
      if (!accepted || !mounted) return false;
      final result = await controller.acceptConsentAndSync(accountKey);
      if (!mounted) return result != null;
      final currentAuth = ref.read(youtubeMusicAuthControllerProvider);
      if (currentAuth.profile?.accountKey.trim() != accountKey) {
        return false;
      }
      final currentSync = ref.read(youtubeMusicPlaylistSyncControllerProvider);
      if (result != null || currentSync.message != null) {
        _showSyncMessage(strings, currentSync);
      }
      return result != null;
    } finally {
      _consentDialogOpen = false;
      _scheduledConsentAccountKey = null;
    }
  }

  Future<void> _syncNow(AppStrings strings) async {
    final controller = ref.read(
      youtubeMusicPlaylistSyncControllerProvider.notifier,
    );
    final result = await controller.syncNow();
    if (!mounted) return;
    final syncState = ref.read(youtubeMusicPlaylistSyncControllerProvider);
    final accountKey = syncState.consentAccountKey;
    if (result == null && syncState.requiresConsent && accountKey != null) {
      await _showConsentPrompt(accountKey, strings);
      return;
    }
    _showSyncMessage(strings, syncState);
  }

  void _showSyncMessage(
    AppStrings strings,
    YouTubeMusicPlaylistSyncState syncState,
  ) {
    final message = syncState.message ?? strings.playlistsSynchronized;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static Future<void> _openPlaylistConflicts(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
  ) async {
    final controller = ref.read(
      youtubeMusicPlaylistSyncControllerProvider.notifier,
    );
    final conflicts = await controller.unresolvedConflicts();
    if (!context.mounted) return;
    if (conflicts.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(strings.noPlaylistSyncConflicts)),
        );
      return;
    }
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => YouTubeMusicPlaylistConflictsDialog(
        conflicts: conflicts,
        strings: strings,
        onResolve: controller.resolveConflict,
      ),
    );
  }
}
