import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/audio_output/audio_output_service.dart';
import '../../../../services/casting/cast_coordinator.dart';
import '../../../../services/player/cast_aware_player_service.dart';
import '../providers/audio_route_providers.dart';
import '../providers/music_providers.dart';
import 'playback_menu_bottom_sheet.dart';

Future<void> showAudioOutputPicker(BuildContext context, WidgetRef ref) async {
  try {
    final player = ref.read(playerServiceProvider);
    if (player is CastAwarePlayerService && player.isCasting) {
      await player.disconnectCast();
    }
    if (!context.mounted) return;
    final shown = await ref.read(audioOutputServiceProvider).showSystemPicker();
    if (!shown && context.mounted) {
      _showOutputUnavailable(context, ref);
    }
  } catch (_) {
    if (context.mounted) _showOutputUnavailable(context, ref);
  }
}

void _showOutputUnavailable(BuildContext context, WidgetRef ref) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(ref.read(appStringsProvider).outputUnavailable)),
  );
}

Future<void> showCastDevicesMenu(BuildContext context) =>
    showPlaybackMenuBottomSheet<void>(
      context: context,
      builder: (_) => const CastDevicesMenu(),
    );

class AudioOutputMenu extends ConsumerStatefulWidget {
  const AudioOutputMenu({super.key});
  @override
  ConsumerState<AudioOutputMenu> createState() => _AudioOutputMenuState();
}

class _AudioOutputMenuState extends ConsumerState<AudioOutputMenu> {
  bool _busy = false;
  String? _message;
  double? _dragVolume;

  Future<void> _select(AudioOutputRoute route) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final strings = ref.read(appStringsProvider);
    try {
      final player = ref.read(playerServiceProvider);
      if (player is CastAwarePlayerService && player.isCasting) {
        await player.disconnectCast();
      }
      final selected = await ref
          .read(audioOutputServiceProvider)
          .selectRoute(route.id);
      if (!selected && mounted) _message = strings.outputUnavailable;
    } catch (_) {
      if (mounted) _message = strings.outputUnavailable;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _systemPicker() async {
    try {
      final player = ref.read(playerServiceProvider);
      if (player is CastAwarePlayerService && player.isCasting) {
        await player.disconnectCast();
      }
      if (!mounted) return;
      if (!await ref.read(audioOutputServiceProvider).showSystemPicker() &&
          mounted) {
        setState(
          () => _message = ref.read(appStringsProvider).outputUnavailable,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = ref.read(appStringsProvider).outputUnavailable,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final output = ref.watch(audioOutputStateProvider);
    final cast = ref.watch(castStateProvider).asData?.value;
    return _RouteMenuLayout(
      menuKey: 'audio-output-menu',
      title: strings.audioOutput,
      children: [
        if (cast?.connected == true)
          ListTile(
            leading: const Icon(Icons.cast_connected_rounded),
            title: Text(cast!.device!.name),
            subtitle: Text(strings.castTo),
            trailing: const Icon(Icons.check_rounded),
          ),
        ...output.when(
          loading: () => [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
          error: (_, _) => [Text(strings.outputLoadFailed)],
          data: (state) => [
            if (!state.supported) Text(strings.outputLoadFailed),
            for (final route in state.routes)
              ListTile(
                key: ValueKey('audio-output-route-${route.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(_outputIcon(route.type)),
                title: Text(
                  route.type == AudioOutputType.speaker
                      ? strings.thisPhone
                      : route.name,
                ),
                subtitle:
                    !state.selectionConfirmed &&
                        state.requestedRouteId == route.id
                    ? Text(strings.outputRequested)
                    : null,
                trailing:
                    route.selected &&
                        state.selectionConfirmed &&
                        cast?.connected != true
                    ? Icon(
                        Icons.check_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                enabled: !_busy && route.selectable,
                onTap: () => _select(route),
              ),
            if (state.hasSystemPicker)
              ListTile(
                key: const ValueKey('audio-output-system-picker'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.settings_bluetooth_rounded),
                title: Text(strings.systemOutputPicker),
                onTap: _busy ? null : _systemPicker,
              ),
            const Divider(height: 24),
            _volume(
              strings: strings,
              value:
                  _dragVolume ??
                  (cast?.connected == true ? cast!.volume : state.volume),
              enabled:
                  !_busy &&
                  (cast?.connected == true || state.volumeAdjustable) &&
                  state.supported,
              remote: cast?.connected == true,
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_message!),
          ),
      ],
    );
  }

  Widget _volume({
    required AppStrings strings,
    required double value,
    required bool enabled,
    required bool remote,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        remote ? strings.deviceVolume : strings.mediaVolume,
        style: Theme.of(context).textTheme.labelLarge,
      ),
      Row(
        children: [
          const Icon(Icons.volume_down_rounded),
          Expanded(
            child: Slider(
              key: const ValueKey('audio-output-volume'),
              value: value.clamp(0, 1),
              onChanged: enabled
                  ? (value) => setState(() => _dragVolume = value)
                  : null,
              onChangeEnd: enabled
                  ? (value) async {
                      try {
                        if (remote) {
                          await ref
                              .read(castCoordinatorProvider)
                              .setVolume(value);
                        } else {
                          await ref
                              .read(audioOutputServiceProvider)
                              .setVolume(value);
                        }
                      } catch (_) {
                        if (mounted) _message = strings.outputUnavailable;
                      } finally {
                        if (mounted) setState(() => _dragVolume = null);
                      }
                    }
                  : null,
            ),
          ),
          const Icon(Icons.volume_up_rounded),
        ],
      ),
    ],
  );
}

class CastDevicesMenu extends ConsumerStatefulWidget {
  const CastDevicesMenu({super.key});
  @override
  ConsumerState<CastDevicesMenu> createState() => _CastDevicesMenuState();
}

class _CastDevicesMenuState extends ConsumerState<CastDevicesMenu> {
  bool _busy = false;
  String? _message;
  late CastCoordinator _coordinator;

  @override
  void initState() {
    super.initState();
    _coordinator = ref.read(castCoordinatorProvider);
    unawaited(_coordinator.startDiscovery());
  }

  @override
  void dispose() {
    unawaited(_coordinator.stopDiscovery());
    super.dispose();
  }

  Future<void> _connect(CastDevice device) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final strings = ref.read(appStringsProvider);
    try {
      final player = ref.read(playerServiceProvider);
      if (player is! CastAwarePlayerService) {
        throw UnsupportedError('Cast backend unavailable.');
      }
      await player.connectCast(device);
    } catch (_) {
      if (mounted) _message = strings.castFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final player = ref.read(playerServiceProvider);
      if (player is CastAwarePlayerService) await player.disconnectCast();
    } catch (_) {
      if (mounted) _message = ref.read(appStringsProvider).castFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final state =
        ref.watch(castStateProvider).asData?.value ?? _coordinator.state;
    final ios = Theme.of(context).platform == TargetPlatform.iOS;
    return _RouteMenuLayout(
      menuKey: 'cast-devices-menu',
      title: strings.castTo,
      children: [
        Text(
          strings.castNetworkHint,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        for (final device in state.devices)
          ListTile(
            key: ValueKey('cast-device-${device.protocol.name}-${device.id}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.speaker_group_rounded),
            title: Text(device.name),
            subtitle: Text(
              device.protocol == CastProtocol.googleCast
                  ? 'Google Cast'
                  : 'DLNA / UPnP',
            ),
            trailing:
                state.device?.id == device.id &&
                    state.device?.protocol == device.protocol
                ? Icon(
                    Icons.check_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
            enabled: !_busy,
            onTap: () => _connect(device),
          ),
        if (state.devices.isEmpty && !state.discovering)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(strings.castNoDevices),
          ),
        if (ios)
          ListTile(
            key: const ValueKey('cast-airplay-picker'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.airplay_rounded),
            title: const Text('AirPlay'),
            enabled: !_busy,
            onTap: () async {
              await _disconnect();
              if (!mounted) return;
              try {
                await ref.read(audioOutputServiceProvider).showSystemPicker();
              } catch (_) {
                if (mounted) {
                  setState(() => _message = strings.outputUnavailable);
                }
              }
            },
          ),
        if (state.connected)
          ListTile(
            key: const ValueKey('cast-disconnect'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cast_rounded),
            title: Text(strings.castDisconnect),
            subtitle: Text(state.device!.name),
            enabled: !_busy,
            onTap: _disconnect,
          ),
        if (state.discovering || _busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    state.discovering ? strings.castSearching : strings.castTo,
                  ),
                ),
              ],
            ),
          ),
        if (_message != null) Text(_message!),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const ValueKey('cast-refresh'),
          onPressed: _busy || state.discovering
              ? null
              : () => _coordinator.startDiscovery(),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(strings.castRefresh),
        ),
      ],
    );
  }
}

class _RouteMenuLayout extends StatelessWidget {
  const _RouteMenuLayout({
    required this.menuKey,
    required this.title,
    required this.children,
  });
  final String menuKey;
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      key: ValueKey(menuKey),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                key: ValueKey('$menuKey-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
}

IconData _outputIcon(AudioOutputType type) => switch (type) {
  AudioOutputType.speaker => Icons.smartphone_rounded,
  AudioOutputType.bluetooth => Icons.bluetooth_audio_rounded,
  AudioOutputType.wired => Icons.headphones_rounded,
  AudioOutputType.usb => Icons.usb_rounded,
  AudioOutputType.other => Icons.speaker_rounded,
};
