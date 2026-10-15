import 'dart:async';

import 'package:flutter/services.dart';

enum AudioOutputType { speaker, wired, bluetooth, usb, other }

class AudioOutputRoute {
  const AudioOutputRoute({
    required this.id,
    required this.name,
    required this.type,
    this.selected = false,
    this.selectable = true,
  });

  final String id;
  final String name;
  final AudioOutputType type;
  final bool selected;
  final bool selectable;

  factory AudioOutputRoute.fromMap(Map<Object?, Object?> map) =>
      AudioOutputRoute(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '',
        type: AudioOutputType.values.firstWhere(
          (type) => type.name == map['type'],
          orElse: () => AudioOutputType.other,
        ),
        selected: map['selected'] == true,
        selectable: map['selectable'] != false,
      );
}

class AudioOutputState {
  const AudioOutputState({
    this.supported = false,
    this.routes = const [],
    this.volume = 0,
    this.hasSystemPicker = false,
    this.volumeAdjustable = true,
    this.requestedRouteId,
    this.selectionConfirmed = true,
  });

  final bool supported;
  final List<AudioOutputRoute> routes;
  final double volume;
  final bool hasSystemPicker;
  final bool volumeAdjustable;
  final String? requestedRouteId;
  final bool selectionConfirmed;

  factory AudioOutputState.fromMap(Map<Object?, Object?> map) =>
      AudioOutputState(
        supported: map['supported'] == true,
        routes: [
          for (final route in map['routes'] as List? ?? const [])
            if (route is Map)
              AudioOutputRoute.fromMap(route.cast<Object?, Object?>()),
        ],
        volume: ((map['volume'] as num?)?.toDouble() ?? 0).clamp(0, 1),
        hasSystemPicker: map['hasSystemPicker'] == true,
        volumeAdjustable: map['volumeAdjustable'] != false,
        requestedRouteId: map['requestedRouteId'] as String?,
        selectionConfirmed: map['selectionConfirmed'] != false,
      );
}

/// Observes media routes only while the output sheet is open. Volume here is
/// the system's multimedia volume, never the player's independent gain.
class AudioOutputService {
  AudioOutputService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('bstream_music/audio_output');

  final MethodChannel _channel;
  final _changes = StreamController<AudioOutputState>.broadcast();
  Stream<AudioOutputState> get changes => _changes.stream;

  Future<AudioOutputState> startWatching() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'audioOutputChanged' && call.arguments is Map) {
        if (!_changes.isClosed) {
          _changes.add(
            AudioOutputState.fromMap(
              (call.arguments as Map).cast<Object?, Object?>(),
            ),
          );
        }
      }
    });
    try {
      await _channel.invokeMethod<void>('startWatching');
      return await getState();
    } on MissingPluginException {
      return const AudioOutputState();
    }
  }

  Future<AudioOutputState> getState() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('getState');
    return AudioOutputState.fromMap(map ?? const {});
  }

  Future<bool> selectRoute(String id) async {
    final result = await _channel.invokeMethod<Object?>('selectRoute', {
      'id': id,
    });
    if (result is Map) {
      final state = AudioOutputState.fromMap(result.cast<Object?, Object?>());
      if (!_changes.isClosed) _changes.add(state);
      return state.supported;
    }
    return result == true;
  }

  Future<bool> showSystemPicker() async =>
      await _channel.invokeMethod<bool>('showSystemPicker') ?? false;

  Future<void> setVolume(double value) =>
      _channel.invokeMethod<void>('setVolume', {'volume': value.clamp(0, 1)});

  Future<void> stopWatching() async {
    try {
      await _channel.invokeMethod<void>('stopWatching');
    } on MissingPluginException {
      // No native output selector on unsupported platforms.
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }

  Future<void> dispose() async {
    await stopWatching();
    await _changes.close();
  }
}
