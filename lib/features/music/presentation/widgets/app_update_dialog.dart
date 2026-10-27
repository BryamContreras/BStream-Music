import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dialog.dart';
import '../../../../services/app_update/github_release_checker.dart';
import '../../../../services/app_update/release_notes_service.dart';
import '../providers/app_strings.dart';
import '../providers/app_update_providers.dart';

Future<void> showAppUpdateAvailableDialog({
  required BuildContext context,
  required AppStrings strings,
  required AppReleaseCheckResult release,
  required Future<void> Function() onDownload,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (dialogContext) => Consumer(
      builder: (context, ref, child) => _AppUpdateAvailableDialog(
        strings: strings,
        release: release,
        service: ref.watch(appReleaseNotesServiceProvider),
        onDownload: onDownload,
      ),
    ),
  );
}

class _AppUpdateAvailableDialog extends StatefulWidget {
  const _AppUpdateAvailableDialog({
    required this.strings,
    required this.release,
    required this.service,
    required this.onDownload,
  });

  final AppStrings strings;
  final AppReleaseCheckResult release;
  final ReleaseNotesService service;
  final Future<void> Function() onDownload;

  @override
  State<_AppUpdateAvailableDialog> createState() =>
      _AppUpdateAvailableDialogState();
}

class _AppUpdateAvailableDialogState extends State<_AppUpdateAvailableDialog> {
  late LocalizedReleaseNotes _notes;
  bool _loading = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _resetNotes();
  }

  @override
  void didUpdateWidget(_AppUpdateAvailableDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.release != widget.release ||
        oldWidget.strings.appLanguage != widget.strings.appLanguage ||
        oldWidget.service != widget.service) {
      _resetNotes();
    }
  }

  void _resetNotes() {
    _notes = widget.service.original(
      widget.release,
      languageCode: widget.strings.appLanguage.code,
    );
    _loading = _notes.items.isNotEmpty;
    unawaited(_loadNotes());
  }

  Future<void> _loadNotes() async {
    final request = ++_request;
    LocalizedReleaseNotes result;
    try {
      result = await widget.service.load(
        widget.release,
        languageCode: widget.strings.appLanguage.code,
      );
    } catch (_) {
      result = LocalizedReleaseNotes(
        items: _notes.items,
        translationFailed: true,
      );
    }
    if (!mounted || request != _request) return;
    setState(() {
      _notes = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final release = widget.release;
    final theme = Theme.of(context);
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AppAlertDialog(
      key: const ValueKey('settings-update-available-dialog'),
      constraints: const BoxConstraints(maxWidth: 560),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      scrollable: true,
      title: Text(strings.updateAvailableTitle),
      content: SizedBox(
        key: const ValueKey('update-release-notes-content'),
        width: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              strings.updateAvailableMessage(
                latestVersion: release.latestVersion,
                currentVersion: release.currentVersion,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              strings.updateReleaseNotesTitle(release.latestVersion),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            if (_loading) ...[
              Text(
                strings.updateReleaseNotesLoading,
                key: const ValueKey('update-release-notes-loading'),
                style: secondaryStyle,
              ),
              const SizedBox(height: 12),
            ],
            if (_notes.items.isEmpty)
              Text(strings.updateReleaseNotesEmpty, style: secondaryStyle)
            else
              for (final item in _notes.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(width: 18, child: Text('•')),
                      Expanded(child: Text(item)),
                    ],
                  ),
                ),
            if (_notes.translationFailed) ...[
              const SizedBox(height: 8),
              Text(
                strings.updateReleaseNotesTranslationFailed,
                style: secondaryStyle,
              ),
              TextButton(
                key: const ValueKey('update-release-notes-retry'),
                onPressed: _loading
                    ? null
                    : () {
                        setState(() => _loading = true);
                        unawaited(_loadNotes());
                      },
                child: Text(strings.retry),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('settings-update-available-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.close),
        ),
        FilledButton(
          key: const ValueKey('settings-update-available-download'),
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(widget.onDownload());
          },
          child: Text(strings.download),
        ),
      ],
    );
  }
}
