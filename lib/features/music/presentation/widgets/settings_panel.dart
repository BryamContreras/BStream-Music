import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/platform/app_platform.dart';
import '../../../../platform_channels/android_file_export_channel.dart';
import '../../../../services/live/tiktok_live_command_service.dart';
import '../providers/music_providers.dart';

class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({super.key});

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  final _downloadPathController = TextEditingController();
  final _tiktokLiveController = TextEditingController();
  final _downloadPathFocusNode = FocusNode();
  final _tiktokLiveFocusNode = FocusNode();
  bool _backupBusy = false;

  @override
  void dispose() {
    _downloadPathController.dispose();
    _tiktokLiveController.dispose();
    _downloadPathFocusNode.dispose();
    _tiktokLiveFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final tiktokLive = AppPlatform.isWindows
        ? ref.watch(tiktokLiveControllerProvider)
        : null;
    final strings = ref.watch(appStringsProvider);
    final sleepTimer = ref.watch(sleepTimerControllerProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.settings,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: settings.when(
              data: (state) {
                _syncControllers(state);
                final tiktokState = tiktokLive?.value;
                if (tiktokState != null) {
                  _syncTikTokController(tiktokState);
                }
                final canChooseDownloadFolder = !AppPlatform.isAndroid;
                return ListView(
                  children: [
                    _SettingsGroup(
                      title: strings.language,
                      children: [
                        _LanguageSelector(
                          language: state.language,
                          strings: strings,
                          onChanged: (language) => ref
                              .read(settingsControllerProvider.notifier)
                              .setLanguage(language),
                        ),
                      ],
                    ),
                    _SettingsGroup(
                      title: strings.sleepTimer,
                      children: [
                        _SleepTimerSettings(
                          state: sleepTimer,
                          strings: strings,
                          onEnabledChanged: ref
                              .read(sleepTimerControllerProvider.notifier)
                              .setEnabled,
                          onDurationSelected: ref
                              .read(sleepTimerControllerProvider.notifier)
                              .selectDuration,
                          onCustomDuration: () =>
                              _chooseSleepTimerDuration(sleepTimer),
                        ),
                      ],
                    ),
                    if (!AppPlatform.isAndroid)
                      _SettingsGroup(
                        title: strings.downloads,
                        children: [
                          _PathField(
                            controller: _downloadPathController,
                            focusNode: _downloadPathFocusNode,
                            label: strings.folder,
                            icon: Icons.folder_rounded,
                            browseTooltip: strings.browseFolder,
                            saveTooltip: strings.save,
                            readOnly: !canChooseDownloadFolder,
                            showActions: canChooseDownloadFolder,
                            onBrowse: _pickDownloadDirectory,
                            onSave: () => ref
                                .read(settingsControllerProvider.notifier)
                                .setDownloadDirectory(
                                  _downloadPathController.text,
                                ),
                          ),
                        ],
                      ),
                    _SettingsGroup(
                      title: strings.backup,
                      children: [
                        _BackupActions(
                          strings: strings,
                          busy: _backupBusy,
                          onExport: _exportBackup,
                          onImport: _importBackup,
                        ),
                      ],
                    ),
                    if (tiktokLive != null)
                      _SettingsGroup(
                        title: strings.liveConnection,
                        children: [
                          tiktokLive.when(
                            data: (state) => _TikTokLiveSettings(
                              controller: _tiktokLiveController,
                              focusNode: _tiktokLiveFocusNode,
                              state: state,
                              strings: strings,
                              onConnect: () => ref
                                  .read(tiktokLiveControllerProvider.notifier)
                                  .connect(_tiktokLiveController.text),
                              onDisconnect: () => ref
                                  .read(tiktokLiveControllerProvider.notifier)
                                  .disconnect(),
                              onCommandAccessChanged: (access) => ref
                                  .read(tiktokLiveControllerProvider.notifier)
                                  .setCommandAccess(access),
                            ),
                            loading: () => const Center(
                              child: CircularProgressIndicator(),
                            ),
                            error: (error, _) => Text(error.toString()),
                          ),
                        ],
                      ),
                    if (AppPlatform.isDesktop)
                      _SettingsGroup(
                        title: strings.desktopTools,
                        children: [
                          Wrap(
                            spacing: 18,
                            runSpacing: 14,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _ToolStatus(
                                label: 'yt-dlp',
                                available: state.hasYtDlp,
                                strings: strings,
                              ),
                              _ToolStatus(
                                label: 'FFmpeg',
                                available: state.hasFfmpeg,
                                strings: strings,
                              ),
                              FilledButton.icon(
                                icon: const Icon(Icons.refresh_rounded),
                                label: Text(strings.verify),
                                onPressed: () => ref
                                    .read(settingsControllerProvider.notifier)
                                    .refreshToolStatus(),
                              ),
                            ],
                          ),
                        ],
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 24),
                      child: Center(
                        child: Text(
                          strings.appVersion(AppConstants.appVersion),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ),
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text(error.toString())),
            ),
          ),
        ],
      ),
    );
  }

  void _syncControllers(SettingsState state) {
    if (!_downloadPathFocusNode.hasFocus &&
        _downloadPathController.text != state.downloadDirectory) {
      _downloadPathController.text = state.downloadDirectory;
    }
  }

  Future<void> _chooseSleepTimerDuration(SleepTimerState timer) async {
    final strings = ref.read(appStringsProvider);
    final controller = TextEditingController(
      text: timer.selectedDuration.inMinutes.toString(),
    );
    final entered = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.timerDuration),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: strings.timerMinutes(30),
            prefixIcon: const Icon(Icons.timer_outlined),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.startTimer),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || entered == null) {
      return;
    }
    final minutes = int.tryParse(entered.trim());
    if (minutes == null || minutes < 1 || minutes > 720) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(strings.invalidTimerDuration)));
      return;
    }
    ref
        .read(sleepTimerControllerProvider.notifier)
        .selectDuration(Duration(minutes: minutes));
  }

  void _syncTikTokController(TikTokLiveState state) {
    if (!_tiktokLiveFocusNode.hasFocus &&
        _tiktokLiveController.text != state.creatorInput) {
      _tiktokLiveController.text = state.creatorInput;
    }
  }

  Future<void> _pickDownloadDirectory() async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: ref.read(appStringsProvider).selectDownloadFolder,
      initialDirectory: _downloadPathController.text.isEmpty
          ? null
          : _downloadPathController.text,
    );
    if (selected == null) {
      return;
    }
    _downloadPathController.text = selected;
    await ref
        .read(settingsControllerProvider.notifier)
        .setDownloadDirectory(selected);
  }

  Future<void> _exportBackup() async {
    if (_backupBusy) {
      return;
    }
    setState(() => _backupBusy = true);
    File? backupFile;
    try {
      final strings = ref.read(appStringsProvider);
      backupFile = await ref
          .read(settingsControllerProvider.notifier)
          .createBackupFile();
      if (!mounted) {
        return;
      }
      final fileName = _backupFileName();
      final String? path;
      if (AppPlatform.isAndroid) {
        path = await const AndroidFileExportChannel().saveFile(
          sourcePath: backupFile.path,
          fileName: fileName,
        );
      } else {
        path = await FilePicker.saveFile(
          dialogTitle: strings.exportBackupTitle,
          fileName: fileName,
          initialDirectory: _downloadPathController.text,
          type: FileType.custom,
          allowedExtensions: const ['zip'],
          lockParentWindow: true,
        );
        if (path != null) {
          await backupFile.copy(path);
        }
      }
      if (!mounted) {
        return;
      }
      _showSnackBar(
        path == null ? strings.backupCancelled : strings.backupExported,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnackBar('${ref.read(appStringsProvider).backupFailed} $error');
    } finally {
      if (backupFile != null && await backupFile.exists()) {
        await backupFile.delete();
      }
      if (mounted) {
        setState(() => _backupBusy = false);
      }
    }
  }

  Future<void> _importBackup() async {
    if (_backupBusy) {
      return;
    }
    setState(() => _backupBusy = true);
    try {
      final strings = ref.read(appStringsProvider);
      final result = await FilePicker.pickFiles(
        dialogTitle: strings.importBackupTitle,
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        withData: false,
        lockParentWindow: true,
      );
      final selected = result?.files.single;
      if (selected == null) {
        if (mounted) {
          _showSnackBar(strings.backupCancelled);
        }
        return;
      }

      final path = selected.path;
      if (path == null) {
        throw const FormatException('No se pudo leer el archivo seleccionado.');
      }
      await ref
          .read(settingsControllerProvider.notifier)
          .restoreBackupFile(path);
      if (!mounted) {
        return;
      }
      _showSnackBar(strings.backupImported);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnackBar('${ref.read(appStringsProvider).backupFailed} $error');
    } finally {
      if (mounted) {
        setState(() => _backupBusy = false);
      }
    }
  }

  String _backupFileName() {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return 'bstream-music-backup-$stamp.zip';
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector({
    required this.language,
    required this.strings,
    required this.onChanged,
  });

  final AppLanguage language;
  final AppStrings strings;
  final ValueChanged<AppLanguage> onChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: SegmentedButton<AppLanguage>(
        selected: {language},
        style: ButtonStyle(
          minimumSize: WidgetStateProperty.all(const Size(0, 58)),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          ),
          textStyle: WidgetStateProperty.all(
            Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          iconSize: WidgetStateProperty.all(24),
        ),
        segments: [
          ButtonSegment(
            value: AppLanguage.spanish,
            icon: const Icon(Icons.language_rounded),
            label: Text(strings.spanish),
          ),
          ButtonSegment(
            value: AppLanguage.english,
            icon: const Icon(Icons.translate_rounded),
            label: Text(strings.english),
          ),
        ],
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

class _SleepTimerSettings extends StatelessWidget {
  const _SleepTimerSettings({
    required this.state,
    required this.strings,
    required this.onEnabledChanged,
    required this.onDurationSelected,
    required this.onCustomDuration,
  });

  static const _presets = [
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 60),
  ];

  final SleepTimerState state;
  final AppStrings strings;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<Duration> onDurationSelected;
  final VoidCallback onCustomDuration;

  @override
  Widget build(BuildContext context) {
    final customSelected = !_presets.contains(state.selectedDuration);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xA0101410),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x70243026)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              value: state.isActive,
              onChanged: onEnabledChanged,
              secondary: const Icon(Icons.bedtime_rounded),
              title: Text(
                strings.automaticShutdown,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                state.isActive
                    ? strings.sleepTimerRemaining(state.remaining)
                    : strings.sleepTimerOff,
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: state.isActive
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              for (
                                var index = 0;
                                index < _presets.length;
                                index++
                              ) ...[
                                if (index > 0) const SizedBox(width: 8),
                                Expanded(
                                  child: _SleepTimerOptionButton(
                                    selected:
                                        state.selectedDuration ==
                                        _presets[index],
                                    inactiveIcon: Icons.schedule_rounded,
                                    label: strings.timerMinutes(
                                      _presets[index].inMinutes,
                                    ),
                                    onTap: () =>
                                        onDurationSelected(_presets[index]),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          _SleepTimerOptionButton(
                            selected: customSelected,
                            inactiveIcon: Icons.tune_rounded,
                            label: strings.customDuration,
                            onTap: onCustomDuration,
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SleepTimerOptionButton extends StatelessWidget {
  const _SleepTimerOptionButton({
    required this.selected,
    required this.inactiveIcon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData inactiveIcon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final borderRadius = BorderRadius.circular(14);
    return SizedBox(
      height: 52,
      child: Material(
        color: selected ? const Color(0xFF435745) : const Color(0x26080B09),
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(
            color: selected ? const Color(0xFF627265) : colors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.check_rounded : inactiveIcon,
                  size: 19,
                  color: selected ? colors.onSurface : colors.primary,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    );
  }
}

class _BackupActions extends StatelessWidget {
  const _BackupActions({
    required this.strings,
    required this.busy,
    required this.onExport,
    required this.onImport,
  });

  final AppStrings strings;
  final bool busy;
  final VoidCallback onExport;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.archive_rounded),
          label: Text(strings.exportBackup),
          onPressed: busy ? null : onExport,
        ),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.unarchive_rounded),
          label: Text(strings.importBackup),
          onPressed: busy ? null : onImport,
        ),
        if (busy)
          const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
      ],
    );
  }
}

class _TikTokLiveSettings extends StatelessWidget {
  const _TikTokLiveSettings({
    required this.controller,
    required this.focusNode,
    required this.state,
    required this.strings,
    required this.onConnect,
    required this.onDisconnect,
    required this.onCommandAccessChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TikTokLiveState state;
  final AppStrings strings;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final ValueChanged<TikTokCommandAccess> onCommandAccessChanged;

  @override
  Widget build(BuildContext context) {
    final connected = state.isConnected;
    final busy = state.isBusy;
    final statusColor = switch (state.status) {
      TikTokLiveBridgeStatus.connected => Theme.of(context).colorScheme.primary,
      TikTokLiveBridgeStatus.error => Theme.of(context).colorScheme.error,
      TikTokLiveBridgeStatus.liveEnded => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.tiktokLive,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: !busy && !connected,
                  decoration: InputDecoration(
                    labelText: strings.tiktokLiveUser,
                    prefixIcon: const Icon(Icons.live_tv_rounded),
                  ),
                  onSubmitted: (_) {
                    if (!connected && !busy) {
                      onConnect();
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              connected
                  ? FilledButton.tonalIcon(
                      icon: const Icon(Icons.link_off_rounded),
                      label: Text(strings.disconnect),
                      onPressed: onDisconnect,
                    )
                  : FilledButton.icon(
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sensors_rounded),
                      label: Text(strings.connect),
                      onPressed: busy ? null : onConnect,
                    ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            strings.commandPermissions,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                avatar: const Icon(Icons.groups_rounded, size: 18),
                label: Text(strings.everyone),
                selected: state.commandAccess == TikTokCommandAccess.everyone,
                onSelected: (_) =>
                    onCommandAccessChanged(TikTokCommandAccess.everyone),
              ),
              ChoiceChip(
                avatar: const Icon(Icons.shield_rounded, size: 18),
                label: Text(strings.moderators),
                selected: state.commandAccess == TikTokCommandAccess.moderators,
                onSelected: (_) =>
                    onCommandAccessChanged(TikTokCommandAccess.moderators),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(_statusIcon(state.status), color: statusColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: statusColor),
                ),
              ),
            ],
          ),
          if (state.roomId != null && state.roomId!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '${strings.roomId}: ${state.roomId}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (state.pendingPlayCommands > 0) ...[
            const SizedBox(height: 6),
            Text(
              '${strings.pendingRequests}: ${state.pendingPlayCommands}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
          if (state.lastCommand != null) ...[
            const SizedBox(height: 6),
            Text(
              '${strings.lastCommand}: ${state.lastCommand!.text}'
              '${state.lastCommand!.isModerator ? ' - ${strings.moderator}' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  IconData _statusIcon(TikTokLiveBridgeStatus status) {
    return switch (status) {
      TikTokLiveBridgeStatus.connected => Icons.check_circle_rounded,
      TikTokLiveBridgeStatus.connecting => Icons.sync_rounded,
      TikTokLiveBridgeStatus.error => Icons.error_rounded,
      TikTokLiveBridgeStatus.liveEnded => Icons.stop_circle_rounded,
      _ => Icons.info_rounded,
    };
  }
}

class _PathField extends StatelessWidget {
  const _PathField({
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.icon,
    required this.browseTooltip,
    required this.saveTooltip,
    this.readOnly = false,
    this.showActions = true,
    required this.onBrowse,
    required this.onSave,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final IconData icon;
  final String browseTooltip;
  final String saveTooltip;
  final bool readOnly;
  final bool showActions;
  final VoidCallback onBrowse;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              readOnly: readOnly,
              decoration: InputDecoration(
                labelText: label,
                prefixIcon: Icon(icon),
              ),
            ),
          ),
          if (showActions) ...[
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: browseTooltip,
              icon: const Icon(Icons.folder_open_rounded),
              onPressed: onBrowse,
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: saveTooltip,
              icon: const Icon(Icons.save_rounded),
              onPressed: onSave,
            ),
          ],
        ],
      ),
    );
  }
}

class _ToolStatus extends StatelessWidget {
  const _ToolStatus({
    required this.label,
    required this.available,
    required this.strings,
  });

  final String label;
  final bool? available;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final color = available == true
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          available == true ? Icons.check_circle_rounded : Icons.error_rounded,
          color: color,
          size: 20,
        ),
        const SizedBox(width: 8),
        Text(
          '$label ${available == true ? strings.available : strings.notFound}',
          style: TextStyle(color: color),
        ),
      ],
    );
  }
}
