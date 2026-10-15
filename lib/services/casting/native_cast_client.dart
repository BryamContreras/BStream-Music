import 'dart:async';

import 'package:flutter/services.dart';

enum NativeCastStatus { idle, loading, playing, paused, completed }

class NativeCastDevice {
  const NativeCastDevice({required this.id, required this.name, this.address});
  final String id;
  final String name;
  final String? address;
}

class NativeCastState {
  const NativeCastState({
    this.supported = false,
    this.devices = const [],
    this.connected = false,
    this.suspended = false,
    this.deviceId,
    this.deviceName,
    this.status = NativeCastStatus.idle,
    this.position = Duration.zero,
    this.duration,
    this.volume = 1,
    this.contentId,
    this.error,
  });

  final bool supported;
  final List<NativeCastDevice> devices;
  final bool connected;
  final bool suspended;
  final String? deviceId;
  final String? deviceName;
  final NativeCastStatus status;
  final Duration position;
  final Duration? duration;
  final double volume;
  final String? contentId;
  final String? error;

  factory NativeCastState.fromMap(Map<Object?, Object?> map) {
    final durationMs = (map['durationMs'] as num?)?.toInt();
    return NativeCastState(
      supported: map['supported'] == true,
      connected: map['connected'] == true,
      suspended: map['suspended'] == true,
      deviceId: map['deviceId'] as String?,
      deviceName: map['deviceName'] as String?,
      status: NativeCastStatus.values.firstWhere(
        (status) => status.name == map['state'],
        orElse: () => NativeCastStatus.idle,
      ),
      position: Duration(
        milliseconds: (map['positionMs'] as num?)?.toInt() ?? 0,
      ),
      duration: durationMs != null && durationMs > 0
          ? Duration(milliseconds: durationMs)
          : null,
      volume: ((map['volume'] as num?)?.toDouble() ?? 1).clamp(0, 1),
      contentId: map['contentId'] as String?,
      error: map['error'] as String?,
      devices: [
        for (final device in map['devices'] as List? ?? const [])
          if (device is Map && device['id'] is String)
            NativeCastDevice(
              id: device['id'] as String,
              name: device['name'] as String? ?? '',
              address: device['address'] as String?,
            ),
      ],
    );
  }
}

/// Cast SDK bridge. Construction does not initialize the SDK or scan Wi-Fi.
class NativeCastClient {
  NativeCastClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('bstream_music/cast');

  final MethodChannel _channel;
  final _changes = StreamController<NativeCastState>.broadcast();
  NativeCastState _state = const NativeCastState();
  bool _initialized = false;

  Stream<NativeCastState> get changes => _changes.stream;
  NativeCastState get state => _state;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'castState' && call.arguments is Map) {
        _accept((call.arguments as Map).cast<Object?, Object?>());
      }
    });
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('getState');
      _accept(map ?? const {});
    } on MissingPluginException {
      _accept(const {});
    } catch (_) {
      _initialized = false;
      rethrow;
    }
  }

  void _accept(Map<Object?, Object?> map) {
    _state = NativeCastState.fromMap(map);
    if (!_changes.isClosed) _changes.add(_state);
  }

  Future<void> startDiscovery() async {
    await initialize();
    if (_state.supported) await _channel.invokeMethod<void>('startDiscovery');
  }

  Future<void> stopDiscovery() async {
    if (_initialized && _state.supported) {
      await _channel.invokeMethod<void>('stopDiscovery');
    }
  }

  Future<void> connect(String id) async {
    await initialize();
    if (!_state.supported) {
      throw StateError('Google Cast is not available on this device.');
    }
    await _channel.invokeMethod<void>('connect', {'id': id});
  }

  Future<void> disconnect({bool stopPlayback = true}) async {
    if (_initialized && _state.supported) {
      await _channel.invokeMethod<void>('disconnect', {
        'stopPlayback': stopPlayback,
      });
    }
  }

  Future<void> load({
    required Uri url,
    required String mimeType,
    required String title,
    required String artist,
    required String contentId,
    Uri? artworkUrl,
    Duration? duration,
    Duration position = Duration.zero,
    bool autoplay = true,
  }) async {
    await _channel.invokeMethod<void>('load', {
      'url': url.toString(),
      'mimeType': mimeType,
      'title': title,
      'artist': artist,
      'contentId': contentId,
      'artworkUrl': artworkUrl?.toString(),
      'positionMs': position.inMilliseconds,
      'durationMs': duration?.inMilliseconds,
      'autoplay': autoplay,
    });
  }

  Future<void> play() => _channel.invokeMethod<void>('play');
  Future<void> pause() => _channel.invokeMethod<void>('pause');
  Future<void> stop() => _channel.invokeMethod<void>('stop');
  Future<void> seek(Duration position) => _channel.invokeMethod<void>('seek', {
    'positionMs': position.inMilliseconds,
  });
  Future<void> setVolume(double volume) =>
      _channel.invokeMethod<void>('setVolume', {'volume': volume.clamp(0, 1)});

  Future<void> dispose() async {
    await stopDiscovery();
    _channel.setMethodCallHandler(null);
    await _changes.close();
  }
}
