import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../platform_channels/android_file_export_channel.dart';
import '../../../../services/live/tiktok_live_command_service.dart';
import '../../../../services/storage/library_csv_import_service.dart';
import '../../../../services/storage/library_csv_service.dart';
import '../providers/music_providers.dart';
import 'lyrics_animation_transition.dart';
import 'scrolled_under_tab_frame.dart';

typedef DownloadDirectoryPicker =
    Future<String?> Function({String? dialogTitle, String? initialDirectory});

final downloadDirectoryPickerProvider = Provider<DownloadDirectoryPicker>((
  ref,
) {
  return ({String? dialogTitle, String? initialDirectory}) =>
      FilePicker.getDirectoryPath(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
      );
});

typedef StorageImportFilePicker =
    Future<FilePickerResult?> Function({
      required String dialogTitle,
      required List<String> allowedExtensions,
    });

final storageImportFilePickerProvider = Provider<StorageImportFilePicker>((
  ref,
) {
  return ({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) => FilePicker.pickFiles(
    dialogTitle: dialogTitle,
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    withData: false,
    lockParentWindow: true,
  );
});

typedef SettingsExternalLauncher = Future<bool> Function(Uri url);

final settingsExternalLauncherProvider = Provider<SettingsExternalLauncher>(
  (ref) =>
      (url) => launchUrl(url, mode: LaunchMode.externalApplication),
);

const _settingsSurfaceRadius = 12.0;
const _settingsInnerRadius = 10.0;
const _settingsCardGap = 8.0;
const _settingsGroupGap = 20.0;
const _settingsGroupHeadingGap = 12.0;

enum _SettingsRoute { root, appearance, lyrics, storage, live, about }

class SettingsNavigationController extends ChangeNotifier {
  _SettingsPanelState? _state;
  bool _disposed = false;

  bool get canPop => _state?._canPop ?? false;

  bool maybePop() => _state?._popRoute() ?? false;

  void _attach(_SettingsPanelState state) {
    _state = state;
  }

  void _detach(_SettingsPanelState state) {
    if (_state == state) {
      _state = null;
    }
  }

  void _routeChanged() => _notifySafely();

  void _notifySafely() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _state = null;
    super.dispose();
  }
}

class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({
    this.active = true,
    this.navigationController,
    super.key,
  });

  final bool active;
  final SettingsNavigationController? navigationController;

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  final _downloadPathController = TextEditingController();
  final _tiktokLiveController = TextEditingController();
  final _downloadPathFocusNode = FocusNode();
  final _tiktokLiveFocusNode = FocusNode();
  bool _backupBusy = false;
  _SettingsRoute _route = _SettingsRoute.root;

  @override
  void initState() {
    super.initState();
    widget.navigationController?._attach(this);
  }

  @override
  void didUpdateWidget(covariant SettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationController != widget.navigationController) {
      oldWidget.navigationController?._detach(this);
      widget.navigationController?._attach(this);
    }
    if (!oldWidget.active && widget.active) {
      _route = _SettingsRoute.root;
    }
  }

  @override
  void dispose() {
    widget.navigationController?._detach(this);
    _downloadPathController.dispose();
    _tiktokLiveController.dispose();
    _downloadPathFocusNode.dispose();
    _tiktokLiveFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final csvTransfer = ref.watch(libraryCsvTransferControllerProvider);
    final supportsTikTokLive =
        AppPlatform.supportsTikTokLive ||
        Theme.of(context).platform == TargetPlatform.android;
    final tiktokLive = supportsTikTokLive
        ? ref.watch(tiktokLiveControllerProvider)
        : null;
    final strings = ref.watch(appStringsProvider);
    final sleepTimer = ref.watch(sleepTimerControllerProvider);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final transitionDuration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 220);

    Widget routeFrame(Widget body) {
      final header = _SettingsHeader(
        route: _route,
        title: _routeTitle(_route, strings),
        strings: strings,
        onBack: _goRoot,
      );
      if (_route != _SettingsRoute.root) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              const SizedBox(height: 16),
              Expanded(child: body),
            ],
          ),
        );
      }
      return ScrolledUnderTabFrame(
        surfaceKey: const ValueKey('settings-tab-header-surface'),
        header: Padding(
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 16),
          child: header,
        ),
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: body,
        ),
      );
    }

    return settings.when(
      data: (state) {
        _syncControllers(state);
        final tiktokState = tiktokLive?.value;
        if (tiktokState != null) {
          _syncTikTokController(tiktokState);
        }
        return AnimatedSwitcher(
          key: const ValueKey('settings-route-switcher'),
          duration: transitionDuration,
          reverseDuration: transitionDuration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            fit: StackFit.expand,
            alignment: Alignment.topLeft,
            children: <Widget>[...previousChildren, ?currentChild],
          ),
          child: KeyedSubtree(
            key: ValueKey('settings-detail-${_route.name}'),
            child: routeFrame(
              _buildRoute(
                state: state,
                sleepTimer: sleepTimer,
                tiktokLive: tiktokLive,
                csvTransfer: csvTransfer,
                strings: strings,
              ),
            ),
          ),
        );
      },
      loading: () =>
          routeFrame(const Center(child: CircularProgressIndicator())),
      error: (error, _) => routeFrame(Center(child: Text(error.toString()))),
    );
  }

  bool get _canPop => _route != _SettingsRoute.root;

  bool _popRoute() {
    if (!_canPop) {
      return false;
    }
    _goRoot();
    return true;
  }

  void _openRoute(_SettingsRoute route) {
    if (route == _route) {
      return;
    }
    setState(() => _route = route);
    widget.navigationController?._routeChanged();
  }

  void _goRoot() {
    if (_route == _SettingsRoute.root) {
      return;
    }
    setState(() => _route = _SettingsRoute.root);
    widget.navigationController?._routeChanged();
  }

  String _routeTitle(_SettingsRoute route, AppStrings strings) {
    return switch (route) {
      _SettingsRoute.root => strings.settings,
      _SettingsRoute.appearance => strings.themeAndAccentColor,
      _SettingsRoute.lyrics => strings.lyricsAppearance,
      _SettingsRoute.storage => strings.storage,
      _SettingsRoute.live => strings.liveConnection,
      _SettingsRoute.about => strings.aboutApplication,
    };
  }

  Widget _buildRoute({
    required SettingsState state,
    required SleepTimerState sleepTimer,
    required AsyncValue<TikTokLiveState>? tiktokLive,
    required LibraryCsvTransferState csvTransfer,
    required AppStrings strings,
  }) {
    if (_route == _SettingsRoute.root) {
      return _buildRoot(
        state: state,
        sleepTimer: sleepTimer,
        tiktokLive: tiktokLive,
        strings: strings,
      );
    }

    final content = switch (_route) {
      _SettingsRoute.appearance => _AppearanceSettings(
        themeMode: state.themeMode,
        accent: state.accent,
        strings: strings,
        onThemeModeChanged: (mode) =>
            ref.read(settingsControllerProvider.notifier).setThemeMode(mode),
        onAccentChanged: (accent) =>
            ref.read(settingsControllerProvider.notifier).setAccent(accent),
      ),
      _SettingsRoute.lyrics => _LyricsAppearanceSettings(
        animationStyle: state.lyricsAnimationStyle,
        alignment: state.lyricsTextAlignment,
        strings: strings,
        onAnimationChanged: (style) => ref
            .read(settingsControllerProvider.notifier)
            .setLyricsAnimationStyle(style),
        onAlignmentChanged: (alignment) => ref
            .read(settingsControllerProvider.notifier)
            .setLyricsTextAlignment(alignment),
      ),
      _SettingsRoute.storage => _StorageSettings(
        strings: strings,
        canChangeDownloadDirectory:
            AppPlatform.isDesktop &&
            Theme.of(context).platform != TargetPlatform.android,
        downloadPathController: _downloadPathController,
        downloadPathFocusNode: _downloadPathFocusNode,
        busy: _backupBusy || csvTransfer.isBusy,
        onBrowse: _pickDownloadDirectory,
        onImportBackup: _importBackup,
        onImportCsv: _importCsv,
        onExportBackup: _exportBackup,
        onExportCsv: _exportCsv,
      ),
      _SettingsRoute.live =>
        tiktokLive == null
            ? Text(strings.liveUnavailable)
            : tiktokLive.when(
                data: (liveState) => _TikTokLiveSettings(
                  controller: _tiktokLiveController,
                  focusNode: _tiktokLiveFocusNode,
                  state: liveState,
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
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Text(error.toString()),
              ),
      _SettingsRoute.about => _AboutApplicationSettings(
        strings: strings,
        onSupport: _openSupportDevelopment,
        onGitHub: _openGitHubRepository,
      ),
      _SettingsRoute.root => const SizedBox.shrink(),
    };

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: content,
          ),
        ),
      ],
    );
  }

  Widget _buildRoot({
    required SettingsState state,
    required SleepTimerState sleepTimer,
    required AsyncValue<TikTokLiveState>? tiktokLive,
    required AppStrings strings,
  }) {
    final liveState = tiktokLive?.value;
    final showDesktopTools =
        AppPlatform.isDesktop &&
        Theme.of(context).platform != TargetPlatform.android;
    return ListView(
      key: const ValueKey('settings-root'),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _SettingsGroup(
          title: strings.general,
          children: [
            _SettingsEntryCard(
              key: const ValueKey('settings-card-language'),
              icon: Icons.language_rounded,
              title: strings.language,
              subtitle: state.language == AppLanguage.spanish
                  ? strings.spanish
                  : strings.english,
              onTap: () => _chooseLanguage(
                currentLanguage: state.language,
                strings: strings,
              ),
            ),
          ],
        ),
        _SettingsGroup(
          title: strings.appearance,
          children: [
            _SettingsEntryCard(
              key: const ValueKey('settings-card-appearance'),
              icon: Icons.palette_rounded,
              title: strings.themeAndAccentColor,
              subtitle:
                  '${strings.themeModeLabel(state.themeMode)} · '
                  '${strings.accentLabel(state.accent)}',
              accent: state.accent.seedColor,
              onTap: () => _openRoute(_SettingsRoute.appearance),
            ),
            const SizedBox(height: _settingsCardGap),
            _SettingsEntryCard(
              key: const ValueKey('settings-card-lyrics-appearance'),
              icon: Icons.lyrics_rounded,
              title: strings.lyrics,
              subtitle:
                  '${strings.lyricsAnimationLabel(state.lyricsAnimationStyle)}'
                  ' · '
                  '${state.lyricsTextAlignment == LyricsTextAlignment.centered ? strings.centeredLyricsAlignment : strings.normalLyricsAlignment}',
              onTap: () => _openRoute(_SettingsRoute.lyrics),
            ),
          ],
        ),
        _SettingsGroup(
          title: strings.playback,
          children: [
            KeyedSubtree(
              key: const ValueKey('settings-inline-timer'),
              child: _SleepTimerSettings(
                state: sleepTimer,
                strings: strings,
                onEnabledChanged: ref
                    .read(sleepTimerControllerProvider.notifier)
                    .setEnabled,
                onDurationSelected: ref
                    .read(sleepTimerControllerProvider.notifier)
                    .selectDuration,
                onCustomDuration: () => _chooseSleepTimerDuration(sleepTimer),
              ),
            ),
          ],
        ),
        _SettingsGroup(
          title: strings.storage,
          children: [
            _SettingsEntryCard(
              key: const ValueKey('settings-card-storage'),
              icon: Icons.storage_rounded,
              title: strings.downloadsAndBackup,
              subtitle: strings.storageSummary,
              onTap: () => _openRoute(_SettingsRoute.storage),
            ),
          ],
        ),
        if (tiktokLive != null)
          _SettingsGroup(
            title: strings.integrations,
            children: [
              _SettingsEntryCard(
                key: const ValueKey('settings-card-live'),
                icon: Icons.live_tv_rounded,
                title: strings.liveConnection,
                subtitle: liveState?.message ?? strings.liveConnectionSummary,
                status: switch (liveState?.status) {
                  TikTokLiveStatus.connected => true,
                  TikTokLiveStatus.error || TikTokLiveStatus.liveEnded => false,
                  _ => null,
                },
                onTap: () => _openRoute(_SettingsRoute.live),
              ),
              const SizedBox(height: _settingsCardGap),
              _LiveRequestStorageCard(
                state: liveState,
                strings: strings,
                onChanged: (value) => ref
                    .read(tiktokLiveControllerProvider.notifier)
                    .setSaveRequestsToLibrary(value),
              ),
            ],
          ),
        if (showDesktopTools)
          _SettingsGroup(
            title: strings.desktopTools,
            children: [
              Wrap(
                key: const ValueKey('settings-inline-tools'),
                spacing: 18,
                runSpacing: 14,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _ToolStatus(
                    label: 'yt-dlp',
                    available: state.hasYtDlp,
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
        _SettingsGroup(
          title: strings.applicationInformation,
          children: [
            _SettingsEntryCard(
              key: const ValueKey('settings-card-about'),
              icon: Icons.info_outline_rounded,
              title: strings.aboutApplication,
              subtitle: strings.aboutApplicationSummary,
              onTap: () => _openRoute(_SettingsRoute.about),
            ),
          ],
        ),
      ],
    );
  }

  void _syncControllers(SettingsState state) {
    if (!_downloadPathFocusNode.hasFocus &&
        _downloadPathController.text != state.downloadDirectory) {
      _downloadPathController.text = state.downloadDirectory;
    }
  }

  Future<void> _chooseLanguage({
    required AppLanguage currentLanguage,
    required AppStrings strings,
  }) async {
    final selected = await showDialog<AppLanguage>(
      context: context,
      builder: (_) =>
          _LanguageSelectorDialog(language: currentLanguage, strings: strings),
    );
    if (!mounted || selected == null || selected == currentLanguage) {
      return;
    }
    await ref.read(settingsControllerProvider.notifier).setLanguage(selected);
  }

  Future<void> _chooseSleepTimerDuration(SleepTimerState timer) async {
    final strings = ref.read(appStringsProvider);
    final entered = await showDialog<String>(
      context: context,
      builder: (_) => _SleepTimerDurationDialog(
        initialDuration: timer.selectedDuration,
        strings: strings,
      ),
    );
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

  Future<void> _openSupportDevelopment() async {
    await _openExternalPage(
      url: AppConstants.supportDevelopmentUrl,
      failureMessage: ref.read(appStringsProvider).supportDevelopmentOpenFailed,
    );
  }

  Future<void> _openGitHubRepository() async {
    await _openExternalPage(
      url: AppConstants.githubRepositoryUrl,
      failureMessage: ref.read(appStringsProvider).githubRepositoryOpenFailed,
    );
  }

  Future<void> _openExternalPage({
    required String url,
    required String failureMessage,
  }) async {
    try {
      final opened = await ref.read(settingsExternalLauncherProvider)(
        Uri.parse(url),
      );
      if (!mounted || opened) {
        return;
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
    }
    _showSnackBar(failureMessage);
  }

  Future<void> _pickDownloadDirectory() async {
    final strings = ref.read(appStringsProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final pickDirectory = ref.read(downloadDirectoryPickerProvider);
    final previousPath = _downloadPathController.text;
    try {
      final selected = await pickDirectory(
        dialogTitle: strings.selectDownloadFolder,
        initialDirectory: previousPath.isEmpty ? null : previousPath,
      );
      if (!mounted || selected == null) {
        return;
      }
      await controller.setDownloadDirectory(selected);
      if (!mounted) {
        return;
      }
      _downloadPathController.text =
          ref.read(settingsControllerProvider).value?.downloadDirectory ??
          selected;
    } catch (_) {
      if (!mounted) {
        return;
      }
      _downloadPathController.text =
          ref.read(settingsControllerProvider).value?.downloadDirectory ??
          previousPath;
      _showSnackBar(strings.downloadFolderSaveFailed);
    }
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
      try {
        if (backupFile != null && await backupFile.exists()) {
          await backupFile.delete();
        }
      } catch (_) {
        // Cleanup failure must never leave Storage permanently disabled.
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
    final strings = ref.read(appStringsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('backup-import-confirmation'),
        title: Text(strings.replaceLibraryTitle),
        content: Text(strings.replaceLibraryMessage),
        actions: [
          TextButton(
            key: const ValueKey('backup-import-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('backup-import-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.restoreAndReplace),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }
    setState(() => _backupBusy = true);
    try {
      final result = await ref.read(storageImportFilePickerProvider)(
        dialogTitle: strings.importBackupTitle,
        allowedExtensions: const ['zip'],
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

  Future<void> _importCsv() async {
    if (_backupBusy || ref.read(libraryCsvTransferControllerProvider).isBusy) {
      return;
    }
    final strings = ref.read(appStringsProvider);
    setState(() => _backupBusy = true);
    try {
      final selection = await ref.read(storageImportFilePickerProvider)(
        dialogTitle: strings.importFromCsv,
        allowedExtensions: const ['csv', 'tsv', 'txt'],
      );
      final selected = selection?.files.single;
      if (selected == null) {
        if (mounted) _showSnackBar(strings.backupCancelled);
        return;
      }
      final path = selected.path;
      if (path == null || path.trim().isEmpty) {
        throw const FormatException('No se pudo leer el archivo seleccionado.');
      }

      final controller = ref.read(
        libraryCsvTransferControllerProvider.notifier,
      );
      controller.reset();
      final document = await controller.preview(path);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => _CsvImportPreviewDialog(
          document: document,
          strings: strings,
          onCancel: () => Navigator.of(dialogContext).pop(false),
          onConfirm: () => Navigator.of(dialogContext).pop(true),
        ),
      );
      if (!mounted || confirmed != true) {
        controller.reset();
        return;
      }

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _CsvImportProgressDialog(document: document, strings: strings),
      );
      controller.reset();
    } catch (error) {
      ref.read(libraryCsvTransferControllerProvider.notifier).reset();
      if (mounted) {
        _showSnackBar('${strings.csvImportFailed} ${_readableCsvError(error)}');
      }
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _exportCsv() async {
    if (_backupBusy || ref.read(libraryCsvTransferControllerProvider).isBusy) {
      return;
    }
    final strings = ref.read(appStringsProvider);
    final profile = await showDialog<LibraryCsvProfile>(
      context: context,
      builder: (dialogContext) => _CsvProfileDialog(
        strings: strings,
        onSelected: (value) => Navigator.of(dialogContext).pop(value),
        onCancel: () => Navigator.of(dialogContext).pop(),
      ),
    );
    if (!mounted || profile == null) return;

    setState(() => _backupBusy = true);
    Directory? transferDirectory;
    try {
      final controller = ref.read(
        libraryCsvTransferControllerProvider.notifier,
      );
      controller.reset();
      final document = await controller.prepareExport();
      final temporaryRoot = await getTemporaryDirectory();
      transferDirectory = await temporaryRoot.createTemp('bstream-csv-');
      final fileName = _csvFileName(profile);
      final source = await ref
          .read(libraryCsvServiceProvider)
          .createExportFile(
            document: document,
            profile: profile,
            outputPath:
                '${transferDirectory.path}${Platform.pathSeparator}$fileName',
          );
      if (!mounted) return;

      final String? destination;
      if (AppPlatform.isAndroid) {
        destination = await const AndroidFileExportChannel().saveFile(
          sourcePath: source.path,
          fileName: fileName,
          mimeType: 'text/csv',
        );
      } else {
        final selectedPath = await FilePicker.saveFile(
          dialogTitle: strings.exportToCsv,
          fileName: fileName,
          initialDirectory: _downloadPathController.text,
          type: FileType.custom,
          allowedExtensions: const ['csv'],
          lockParentWindow: true,
        );
        destination = selectedPath == null
            ? null
            : _ensureCsvExtension(selectedPath);
        if (destination != null) await source.copy(destination);
      }
      if (!mounted) return;
      _showSnackBar(
        destination == null ? strings.backupCancelled : strings.csvExported,
      );
      controller.reset();
    } catch (error) {
      ref.read(libraryCsvTransferControllerProvider.notifier).reset();
      if (mounted) {
        _showSnackBar('${strings.csvExportFailed} ${_readableCsvError(error)}');
      }
    } finally {
      try {
        if (transferDirectory != null && await transferDirectory.exists()) {
          await transferDirectory.delete(recursive: true);
        }
      } catch (_) {
        // Cleanup must never leave Storage permanently disabled.
      }
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  String _backupFileName() {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return 'bstream-music-backup-$stamp.zip';
  }

  String _csvFileName(LibraryCsvProfile profile) {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return 'bstream-music-${profile.name}-$stamp.csv';
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _CsvImportPreviewDialog extends StatelessWidget {
  const _CsvImportPreviewDialog({
    required this.document,
    required this.strings,
    required this.onCancel,
    required this.onConfirm,
  });

  final LibraryCsvDocument document;
  final AppStrings strings;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('csv-import-preview'),
      scrollable: true,
      title: Text(strings.csvImportTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Chip(
                avatar: const Icon(Icons.table_view_rounded, size: 18),
                label: Text(_csvDetectedFormatLabel(document.detectedFormat)),
              ),
              const SizedBox(height: 12),
              Text(
                strings.csvImportPreview(
                  tracks: document.uniqueTrackCount,
                  playlists: document.playlistCount,
                  invalid: document.invalidRowCount,
                  duplicates: document.duplicateRowCount,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(strings.csvImportDataNotice)),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('csv-import-preview-cancel'),
          onPressed: onCancel,
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('csv-import-preview-confirm'),
          onPressed: onConfirm,
          child: Text(strings.importAndDownload),
        ),
      ],
    );
  }
}

class _CsvImportProgressDialog extends ConsumerStatefulWidget {
  const _CsvImportProgressDialog({
    required this.document,
    required this.strings,
  });

  final LibraryCsvDocument document;
  final AppStrings strings;

  @override
  ConsumerState<_CsvImportProgressDialog> createState() =>
      _CsvImportProgressDialogState();
}

class _CsvImportProgressDialogState
    extends ConsumerState<_CsvImportProgressDialog> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _started = true);
      unawaited(_runImport());
    });
  }

  Future<void> _runImport() async {
    try {
      await ref
          .read(libraryCsvTransferControllerProvider.notifier)
          .importDocument(widget.document);
    } catch (_) {
      // The controller publishes the terminal error for this dialog.
    }
  }

  @override
  Widget build(BuildContext context) {
    final transfer = ref.watch(libraryCsvTransferControllerProvider);
    final progress = transfer.progress;
    final result = transfer.result;
    final failed = transfer.phase == LibraryCsvTransferPhase.failed;
    final completed = result != null;
    final terminal = failed || completed;
    final cancelRequested = transfer.cancelRequested;

    return PopScope(
      canPop: terminal,
      child: AlertDialog(
        key: const ValueKey('csv-import-progress-dialog'),
        scrollable: true,
        title: Text(
          failed
              ? widget.strings.csvImportFailed
              : completed
              ? widget.strings.csvImportCompleted
              : widget.strings.csvImporting,
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: _buildContent(
              context,
              progress: progress,
              result: result,
              error: transfer.error,
              failed: failed,
              started: _started,
              cancelRequested: cancelRequested,
            ),
          ),
        ),
        actions: [
          if (!terminal)
            TextButton(
              key: const ValueKey('csv-import-request-cancel'),
              onPressed: cancelRequested
                  ? null
                  : () => ref
                        .read(libraryCsvTransferControllerProvider.notifier)
                        .requestCancel(),
              child: Text(
                cancelRequested
                    ? widget.strings.csvStopRequested
                    : widget.strings.stopAfterCurrent,
              ),
            ),
          if (terminal)
            FilledButton(
              key: const ValueKey('csv-import-close'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(widget.strings.close),
            ),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required LibraryCsvImportProgress? progress,
    required LibraryCsvImportResult? result,
    required Object? error,
    required bool failed,
    required bool started,
    required bool cancelRequested,
  }) {
    if (result != null) {
      final details = result.failures.take(3).toList(growable: false);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            result.cancelled
                ? Icons.stop_circle_outlined
                : Icons.check_circle_rounded,
            size: 40,
            color: result.cancelled
                ? Theme.of(context).colorScheme.tertiary
                : Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            widget.strings.csvImportResult(
              downloaded: result.downloaded,
              reused: result.reused,
              failed: result.failed,
              playlists: result.playlistsUpdated,
            ),
          ),
          if (result.cancelled) ...[
            const SizedBox(height: 8),
            Text(widget.strings.csvImportCancelled),
          ],
          if (details.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final failure in details)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${failure.title}: ${_readableCsvError(failure.message)}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ],
      );
    }
    if (failed) {
      return Text(
        '${widget.strings.csvImportFailed}\n${_readableCsvError(error)}',
        key: const ValueKey('csv-import-error'),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }

    final processed = progress?.processed ?? 0;
    final total = progress?.total ?? widget.document.uniqueTrackCount;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          key: const ValueKey('csv-import-progress'),
          value: started && progress != null ? progress.fraction : null,
        ),
        const SizedBox(height: 12),
        Text(widget.strings.csvImportProgress(processed, total)),
        if ((progress?.currentTitle ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            progress!.currentTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (cancelRequested) ...[
          const SizedBox(height: 10),
          Text(widget.strings.csvStopRequested),
        ],
      ],
    );
  }
}

class _CsvProfileDialog extends StatelessWidget {
  const _CsvProfileDialog({
    required this.strings,
    required this.onSelected,
    required this.onCancel,
  });

  final AppStrings strings;
  final ValueChanged<LibraryCsvProfile> onSelected;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final options = <(LibraryCsvProfile, String, String)>[
      (
        LibraryCsvProfile.bstream,
        strings.csvProfileBStream,
        strings.csvProfileBStreamSummary,
      ),
      (
        LibraryCsvProfile.metroList,
        strings.csvProfileMetroList,
        strings.csvProfileMetroListSummary,
      ),
      (
        LibraryCsvProfile.harmony,
        strings.csvProfileHarmony,
        strings.csvProfileHarmonySummary,
      ),
      (
        LibraryCsvProfile.soundiiz,
        strings.csvProfileSoundiiz,
        strings.csvProfileSoundiizSummary,
      ),
    ];
    return AlertDialog(
      key: const ValueKey('csv-export-profile-dialog'),
      scrollable: true,
      title: Text(strings.chooseCsvProfile),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < options.length; index++) ...[
                if (index > 0) const SizedBox(height: 6),
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(_settingsSurfaceRadius),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: ValueKey('csv-profile-${options[index].$1.name}'),
                    minVerticalPadding: 10,
                    title: Text(options[index].$2),
                    subtitle: Text(options[index].$3, maxLines: 3),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => onSelected(options[index].$1),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('csv-export-profile-cancel'),
          onPressed: onCancel,
          child: Text(strings.cancel),
        ),
      ],
    );
  }
}

String _csvDetectedFormatLabel(LibraryCsvDetectedFormat format) =>
    switch (format) {
      LibraryCsvDetectedFormat.bstream => 'BStream',
      LibraryCsvDetectedFormat.metroList => 'MetroList',
      LibraryCsvDetectedFormat.harmony => 'Harmony / RiMusic',
      LibraryCsvDetectedFormat.exportify => 'Exportify',
      LibraryCsvDetectedFormat.soundiiz => 'Soundiiz',
      LibraryCsvDetectedFormat.generic => 'CSV',
    };

String _ensureCsvExtension(String path) =>
    path.toLowerCase().endsWith('.csv') ? path : '$path.csv';

String _readableCsvError(Object? error) {
  if (error == null) return '';
  var message = error.toString().trim();
  message = message.replaceFirst(
    RegExp(r'^(?:FormatException|Exception|StateError):\s*'),
    '',
  );
  final lines = message
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .take(3)
      .join('\n');
  final readable = lines.isEmpty ? message : lines;
  return readable.length <= 600 ? readable : '${readable.substring(0, 597)}...';
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({
    required this.route,
    required this.title,
    required this.strings,
    required this.onBack,
  });

  final _SettingsRoute route;
  final String title;
  final AppStrings strings;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800);
    if (route == _SettingsRoute.root) {
      return Text(
        key: const ValueKey('settings-tab-title'),
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('settings-detail-back'),
            tooltip: strings.back,
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              key: const ValueKey('settings-detail-title'),
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsEntryCard extends StatelessWidget {
  const _SettingsEntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent,
    this.status,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? accent;
  final bool? status;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final highlight = accent ?? colors.primary;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Material(
        color: AppColors.cardSurfaceFor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_settingsSurfaceRadius),
          side: BorderSide(color: AppColors.cardBorderFor(context)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 78),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: highlight.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(_settingsInnerRadius),
                      border: Border.all(
                        color: highlight.withValues(alpha: 0.24),
                      ),
                    ),
                    child: Icon(icon, color: highlight, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (status != null) ...[
                    const SizedBox(width: 8),
                    Icon(
                      status!
                          ? Icons.check_circle_rounded
                          : Icons.error_rounded,
                      color: status! ? colors.primary : colors.error,
                      size: 19,
                    ),
                  ],
                  if (trailing case final trailing?) ...[
                    const SizedBox(width: 8),
                    trailing,
                  ] else if (onTap != null) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AboutApplicationSettings extends StatelessWidget {
  const _AboutApplicationSettings({
    required this.strings,
    required this.onSupport,
    required this.onGitHub,
  });

  final AppStrings strings;
  final VoidCallback onSupport;
  final VoidCallback onGitHub;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SettingsEntryCard(
          key: const ValueKey('settings-about-version'),
          icon: Icons.sell_outlined,
          title: strings.versionLabel,
          subtitle: AppConstants.appVersion,
          onTap: null,
        ),
        const SizedBox(height: _settingsCardGap),
        _SettingsEntryCard(
          key: const ValueKey('settings-about-support'),
          icon: Icons.favorite_outline_rounded,
          title: strings.supportDevelopmentTitle,
          subtitle: strings.supportDevelopmentBody,
          onTap: onSupport,
        ),
        const SizedBox(height: _settingsCardGap),
        _SettingsEntryCard(
          key: const ValueKey('settings-about-github'),
          icon: Icons.code_rounded,
          title: strings.githubRepositoryTitle,
          subtitle: strings.githubRepositoryBody,
          onTap: onGitHub,
        ),
      ],
    );
  }
}

class _LanguageSelectorDialog extends StatelessWidget {
  const _LanguageSelectorDialog({
    required this.language,
    required this.strings,
  });

  final AppLanguage language;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('settings-language-dialog'),
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(strings.language),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LanguageDialogOption(
              key: const ValueKey('settings-language-option-spanish'),
              language: AppLanguage.spanish,
              selected: language == AppLanguage.spanish,
              icon: Icons.language_rounded,
              label: strings.spanish,
            ),
            const SizedBox(height: 8),
            _LanguageDialogOption(
              key: const ValueKey('settings-language-option-english'),
              language: AppLanguage.english,
              selected: language == AppLanguage.english,
              icon: Icons.translate_rounded,
              label: strings.english,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('settings-language-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
      ],
    );
  }
}

class _LanguageDialogOption extends StatelessWidget {
  const _LanguageDialogOption({
    required this.language,
    required this.selected,
    required this.icon,
    required this.label,
    super.key,
  });

  final AppLanguage language;
  final bool selected;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: selected
            ? colors.primaryContainer.withValues(alpha: 0.72)
            : colors.surfaceContainerHighest.withValues(alpha: 0.72),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_settingsInnerRadius),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pop(language),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(icon, color: selected ? colors.primary : null),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: selected ? colors.onPrimaryContainer : null,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings({
    required this.themeMode,
    required this.accent,
    required this.strings,
    required this.onThemeModeChanged,
    required this.onAccentChanged,
  });

  final AppThemeMode themeMode;
  final AppAccent accent;
  final AppStrings strings;
  final ValueChanged<AppThemeMode> onThemeModeChanged;
  final ValueChanged<AppAccent> onAccentChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.theme,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          SegmentedButton<AppThemeMode>(
            selected: {themeMode},
            style: ButtonStyle(
              minimumSize: WidgetStateProperty.all(const Size(0, 50)),
              padding: WidgetStateProperty.all(
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              textStyle: WidgetStateProperty.all(
                Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              iconSize: WidgetStateProperty.all(22),
            ),
            segments: [
              ButtonSegment(
                value: AppThemeMode.system,
                icon: const Icon(Icons.settings_suggest_rounded),
                label: Text(strings.themeSystem),
              ),
              ButtonSegment(
                value: AppThemeMode.light,
                icon: const Icon(Icons.light_mode_rounded),
                label: Text(strings.themeLight),
              ),
              ButtonSegment(
                value: AppThemeMode.dark,
                icon: const Icon(Icons.dark_mode_rounded),
                label: Text(strings.themeDark),
              ),
            ],
            onSelectionChanged: (selection) =>
                onThemeModeChanged(selection.first),
          ),
          const SizedBox(height: 16),
          Text(
            strings.accentColor,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 328),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columnCount = constraints.maxWidth < 328 ? 5 : 6;
                  return GridView.builder(
                    key: const ValueKey('accent-palette-grid'),
                    shrinkWrap: true,
                    primary: false,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columnCount,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: AppAccent.values.length,
                    itemBuilder: (context, index) {
                      final option = AppAccent.values[index];
                      return _AccentSwatch(
                        accent: option,
                        selected: option == accent,
                        label: strings.accentLabel(option),
                        onTap: () => onAccentChanged(option),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsAppearanceSettings extends StatelessWidget {
  const _LyricsAppearanceSettings({
    required this.animationStyle,
    required this.alignment,
    required this.strings,
    required this.onAnimationChanged,
    required this.onAlignmentChanged,
  });

  final LyricsAnimationStyle animationStyle;
  final LyricsTextAlignment alignment;
  final AppStrings strings;
  final ValueChanged<LyricsAnimationStyle> onAnimationChanged;
  final ValueChanged<LyricsTextAlignment> onAlignmentChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.lyricsAnimation,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Wrap(
            key: const ValueKey('lyrics-animation-options'),
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in LyricsAnimationStyle.values)
                ChoiceChip(
                  key: ValueKey('lyrics-animation-option-${option.code}'),
                  selected: animationStyle == option,
                  showCheckmark: true,
                  avatar: Icon(_lyricsAnimationIcon(option), size: 18),
                  label: Text(strings.lyricsAnimationLabel(option)),
                  onSelected: (_) => onAnimationChanged(option),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            strings.lyricsAlignment,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<LyricsTextAlignment>(
              key: const ValueKey('lyrics-alignment-options'),
              selected: {alignment},
              segments: [
                ButtonSegment(
                  value: LyricsTextAlignment.normal,
                  icon: const Icon(Icons.format_align_left_rounded),
                  label: Text(strings.normalLyricsAlignment),
                ),
                ButtonSegment(
                  value: LyricsTextAlignment.centered,
                  icon: const Icon(Icons.format_align_center_rounded),
                  label: Text(strings.centeredLyricsAlignment),
                ),
              ],
              onSelectionChanged: (selection) =>
                  onAlignmentChanged(selection.first),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            strings.lyricsPreview,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          _LyricsAnimationPreview(
            animationStyle: animationStyle,
            alignment: alignment,
            strings: strings,
          ),
        ],
      ),
    );
  }
}

IconData _lyricsAnimationIcon(LyricsAnimationStyle style) => switch (style) {
  LyricsAnimationStyle.smooth => Icons.auto_awesome_rounded,
  LyricsAnimationStyle.slide => Icons.swipe_up_rounded,
  LyricsAnimationStyle.highlight => Icons.zoom_in_rounded,
  LyricsAnimationStyle.none => Icons.motion_photos_off_rounded,
};

class _LyricsAnimationPreview extends StatefulWidget {
  const _LyricsAnimationPreview({
    required this.animationStyle,
    required this.alignment,
    required this.strings,
  });

  final LyricsAnimationStyle animationStyle;
  final LyricsTextAlignment alignment;
  final AppStrings strings;

  @override
  State<_LyricsAnimationPreview> createState() =>
      _LyricsAnimationPreviewState();
}

class _LyricsAnimationPreviewState extends State<_LyricsAnimationPreview> {
  int _replayToken = 0;

  @override
  void didUpdateWidget(covariant _LyricsAnimationPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animationStyle != widget.animationStyle ||
        oldWidget.alignment != widget.alignment) {
      _replayToken++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = colors.primary;
    final centered = widget.alignment == LyricsTextAlignment.centered;
    final textAlign = centered ? TextAlign.center : TextAlign.start;
    return Container(
      key: const ValueKey('lyrics-animation-preview'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF111715), Color(0xFF030504)],
        ),
        borderRadius: BorderRadius.circular(_settingsSurfaceRadius),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.strings.lyricsPreviewPreviousLine,
            key: const ValueKey('lyrics-preview-previous-line'),
            textAlign: textAlign,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.38),
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 13),
          LyricsAnimationPreviewTransition(
            key: ValueKey(
              'lyrics-preview-${widget.animationStyle.code}-'
              '${widget.alignment.name}-$_replayToken',
            ),
            style: widget.animationStyle,
            accent: accent,
            alignment: centered ? Alignment.center : Alignment.centerLeft,
            child: Text(
              widget.strings.lyricsPreviewActiveLine,
              key: const ValueKey('lyrics-preview-active-line'),
              textAlign: textAlign,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                height: 1.15,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 13),
          Text(
            widget.strings.lyricsPreviewNextLine,
            key: const ValueKey('lyrics-preview-next-line'),
            textAlign: textAlign,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.38),
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: centered ? Alignment.center : Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('lyrics-preview-replay'),
              onPressed: () => setState(() => _replayToken++),
              style: TextButton.styleFrom(foregroundColor: accent),
              icon: const Icon(Icons.replay_rounded, size: 18),
              label: Text(widget.strings.replayAnimation),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.accent,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final AppAccent accent;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: ValueKey('accent-${accent.code}'),
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(_settingsInnerRadius),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [accent.seedColor, accent.darkColor],
              ),
              borderRadius: BorderRadius.circular(_settingsInnerRadius),
              border: Border.all(
                color: selected ? scheme.onSurface : scheme.outlineVariant,
                width: selected ? 3 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: accent.seedColor.withValues(alpha: 0.38),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: selected
                ? Icon(
                    Icons.check_rounded,
                    color: accent.seedColor.computeLuminance() > 0.58
                        ? Colors.black
                        : Colors.white,
                    size: 22,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _SleepTimerDurationDialog extends StatefulWidget {
  const _SleepTimerDurationDialog({
    required this.initialDuration,
    required this.strings,
  });

  final Duration initialDuration;
  final AppStrings strings;

  @override
  State<_SleepTimerDurationDialog> createState() =>
      _SleepTimerDurationDialogState();
}

class _SleepTimerDurationDialogState extends State<_SleepTimerDurationDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialDuration.inMinutes.toString(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      title: Text(strings.timerDuration),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: strings.timerMinutes(30),
          prefixIcon: const Icon(Icons.timer_outlined),
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(strings.startTimer),
        ),
      ],
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
      child: Material(
        color: AppColors.cardSurfaceFor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_settingsSurfaceRadius),
          side: BorderSide(color: AppColors.cardBorderFor(context)),
        ),
        clipBehavior: Clip.antiAlias,
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
    final borderRadius = BorderRadius.circular(_settingsInnerRadius);
    return SizedBox(
      height: 52,
      child: Material(
        color: selected
            ? colors.primaryContainer
            : colors.surfaceContainerHighest.withValues(alpha: 0.58),
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
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
      padding: const EdgeInsets.only(bottom: _settingsGroupGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: _settingsGroupHeadingGap),
          ...children,
        ],
      ),
    );
  }
}

class _StorageSettings extends StatelessWidget {
  const _StorageSettings({
    required this.strings,
    required this.canChangeDownloadDirectory,
    required this.downloadPathController,
    required this.downloadPathFocusNode,
    required this.busy,
    required this.onBrowse,
    required this.onImportBackup,
    required this.onImportCsv,
    required this.onExportBackup,
    required this.onExportCsv,
  });

  final AppStrings strings;
  final bool canChangeDownloadDirectory;
  final TextEditingController downloadPathController;
  final FocusNode downloadPathFocusNode;
  final bool busy;
  final VoidCallback onBrowse;
  final VoidCallback onImportBackup;
  final VoidCallback onImportCsv;
  final VoidCallback onExportBackup;
  final VoidCallback onExportCsv;

  @override
  Widget build(BuildContext context) {
    final headingStyle = Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(strings.downloads, style: headingStyle),
        const SizedBox(height: 14),
        _PathField(
          controller: downloadPathController,
          focusNode: downloadPathFocusNode,
          label: strings.folder,
          icon: Icons.folder_rounded,
          browseTooltip: strings.browseFolder,
          onBrowse: canChangeDownloadDirectory ? onBrowse : null,
        ),
        const SizedBox(height: _settingsGroupGap),
        _StorageTransferSection(
          title: strings.importData,
          children: [
            _SettingsEntryCard(
              key: const ValueKey('storage-import-backup'),
              icon: Icons.settings_backup_restore_rounded,
              title: strings.importFromLocalBackup,
              subtitle: strings.importBackupSummary,
              onTap: busy ? null : onImportBackup,
            ),
            const SizedBox(height: _settingsCardGap),
            _SettingsEntryCard(
              key: const ValueKey('storage-import-csv'),
              icon: Icons.upload_file_rounded,
              title: strings.importFromCsv,
              subtitle: strings.importCsvSummary,
              onTap: busy ? null : onImportCsv,
            ),
          ],
        ),
        const SizedBox(height: _settingsGroupGap),
        _StorageTransferSection(
          title: strings.exportData,
          children: [
            _SettingsEntryCard(
              key: const ValueKey('storage-export-backup'),
              icon: Icons.inventory_2_rounded,
              title: strings.exportLocalBackup,
              subtitle: strings.exportBackupSummary,
              onTap: busy ? null : onExportBackup,
            ),
            const SizedBox(height: _settingsCardGap),
            _SettingsEntryCard(
              key: const ValueKey('storage-export-csv'),
              icon: Icons.download_for_offline_rounded,
              title: strings.exportToCsv,
              subtitle: strings.exportCsvSummary,
              onTap: busy ? null : onExportCsv,
            ),
          ],
        ),
      ],
    );
  }
}

class _StorageTransferSection extends StatelessWidget {
  const _StorageTransferSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: _settingsGroupHeadingGap),
        ...children,
      ],
    );
  }
}

class _LiveRequestStorageCard extends StatelessWidget {
  const _LiveRequestStorageCard({
    required this.state,
    required this.strings,
    required this.onChanged,
  });

  final TikTokLiveState? state;
  final AppStrings strings;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final liveState = state;
    final savesToLibrary = liveState?.saveRequestsToLibrary ?? false;
    final hasQueuedRequests = liveState?.liveQueue.isNotEmpty ?? false;
    final canChange = liveState != null && !hasQueuedRequests;
    return _SettingsEntryCard(
      key: const ValueKey('settings-card-live-request-storage'),
      icon: savesToLibrary
          ? Icons.library_add_check_rounded
          : Icons.cloud_queue_rounded,
      title: strings.saveLiveRequestsToLibrary,
      subtitle: hasQueuedRequests
          ? strings.saveLiveRequestsToLibraryLocked
          : savesToLibrary
          ? strings.saveLiveRequestsToLibraryEnabled
          : strings.saveLiveRequestsToLibraryDisabled,
      onTap: canChange ? () => onChanged(!savesToLibrary) : null,
      trailing: Switch.adaptive(
        key: const ValueKey('tiktok-live-save-requests-to-library'),
        value: savesToLibrary,
        onChanged: canChange ? onChanged : null,
      ),
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
      TikTokLiveStatus.connected => Theme.of(context).colorScheme.primary,
      TikTokLiveStatus.error => Theme.of(context).colorScheme.error,
      TikTokLiveStatus.liveEnded => Theme.of(context).colorScheme.error,
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
          LayoutBuilder(
            builder: (context, constraints) {
              final input = TextField(
                key: const ValueKey('tiktok-live-user-field'),
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
              );
              final action = connected || busy
                  ? FilledButton.tonalIcon(
                      key: const ValueKey('tiktok-live-disconnect'),
                      icon: Icon(
                        busy ? Icons.close_rounded : Icons.link_off_rounded,
                      ),
                      label: Text(strings.disconnect),
                      onPressed: onDisconnect,
                    )
                  : FilledButton.icon(
                      key: const ValueKey('tiktok-live-connect'),
                      icon: const Icon(Icons.sensors_rounded),
                      label: Text(strings.connect),
                      onPressed: onConnect,
                    );
              if (constraints.maxWidth < 600) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    input,
                    const SizedBox(height: 10),
                    SizedBox(height: 48, child: action),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: input),
                  const SizedBox(width: 10),
                  action,
                ],
              );
            },
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

  IconData _statusIcon(TikTokLiveStatus status) {
    return switch (status) {
      TikTokLiveStatus.connected => Icons.check_circle_rounded,
      TikTokLiveStatus.connecting => Icons.sync_rounded,
      TikTokLiveStatus.error => Icons.error_rounded,
      TikTokLiveStatus.liveEnded => Icons.stop_circle_rounded,
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
    required this.onBrowse,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final IconData icon;
  final String browseTooltip;
  final VoidCallback? onBrowse;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('download-directory-field'),
              controller: controller,
              focusNode: focusNode,
              readOnly: true,
              decoration: InputDecoration(
                labelText: label,
                prefixIcon: Icon(icon),
              ),
            ),
          ),
          if (onBrowse != null) ...[
            const SizedBox(width: 10),
            IconButton.filledTonal(
              key: const ValueKey('download-directory-browse'),
              tooltip: browseTooltip,
              icon: const Icon(Icons.folder_open_rounded),
              onPressed: onBrowse,
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
