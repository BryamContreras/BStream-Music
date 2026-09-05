import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_dialog.dart';
import '../../../../services/app_update/github_release_checker.dart';
import '../providers/app_strings.dart';

Future<void> showAppUpdateAvailableDialog({
  required BuildContext context,
  required AppStrings strings,
  required AppReleaseCheckResult release,
  required Future<void> Function() onDownload,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (dialogContext) => AppAlertDialog(
      key: const ValueKey('settings-update-available-dialog'),
      title: Text(strings.updateAvailableTitle),
      content: Text(
        strings.updateAvailableMessage(
          latestVersion: release.latestVersion,
          currentVersion: release.currentVersion,
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('settings-update-available-close'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(strings.close),
        ),
        FilledButton(
          key: const ValueKey('settings-update-available-download'),
          onPressed: () {
            Navigator.of(dialogContext).pop();
            unawaited(onDownload());
          },
          child: Text(strings.download),
        ),
      ],
    ),
  );
}
