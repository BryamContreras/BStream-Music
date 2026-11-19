part of 'just_audio.dart';

/// A read-only snapshot of BStream's own PCM processor. No system AudioEffect
/// objects, microphone access or audio samples are passed across this channel.
class BStreamEqualizerStatus {
  const BStreamEqualizerStatus({
    required this.supported,
    required this.enabled,
    required this.configured,
    required this.parameters,
    this.engine = 'bstream-dsp',
    this.preampDb = 0,
    this.processedFrames = 0,
    this.sampleRate = 0,
    this.channelCount = 0,
    this.pcmEncoding = 0,
    this.lastAudioTrackEncoding = 0,
    this.lastAudioTrackSampleRate = 0,
    this.revision = 0,
    this.appliedRevision = -1,
    this.skipSilenceSupported,
  });

  final bool supported;
  final bool enabled;
  final bool configured;
  final String engine;
  final double preampDb;
  final int processedFrames;
  final int sampleRate;
  final int channelCount;
  final int pcmEncoding;

  /// The last format opened with Android's audio output, after processing.
  final int lastAudioTrackEncoding;
  final int lastAudioTrackSampleRate;
  final int revision;
  final int appliedRevision;

  /// Darwin reports support for the current asset, independently from EQ.
  /// Null preserves the Android backend's platform-level capability.
  final bool? skipSilenceSupported;
  final BStreamEqualizerParameters parameters;

  /// The processor is owned by this player, without a shared system control.
  bool get hasControl => supported;

  factory BStreamEqualizerStatus.fromMap(Map<dynamic, dynamic> map) {
    final raw = map['parameters'];
    final parameters = raw is Map ? raw : const <dynamic, dynamic>{};
    final bands = parameters['bands'];
    return BStreamEqualizerStatus(
      supported: map['supported'] == true,
      enabled: map['enabled'] == true,
      configured: map['configured'] == true,
      engine: map['engine'] as String? ?? '',
      preampDb: (map['preampDb'] as num?)?.toDouble() ?? 0,
      processedFrames: (map['processedFrames'] as num?)?.toInt() ?? 0,
      sampleRate: (map['sampleRate'] as num?)?.toInt() ?? 0,
      channelCount: (map['channelCount'] as num?)?.toInt() ?? 0,
      pcmEncoding: (map['pcmEncoding'] as num?)?.toInt() ?? 0,
      lastAudioTrackEncoding:
          (map['lastAudioTrackEncoding'] as num?)?.toInt() ?? 0,
      lastAudioTrackSampleRate:
          (map['lastAudioTrackSampleRate'] as num?)?.toInt() ?? 0,
      revision: (map['revision'] as num?)?.toInt() ?? 0,
      appliedRevision: (map['appliedRevision'] as num?)?.toInt() ?? -1,
      skipSilenceSupported: map['skipSilenceSupported'] as bool?,
      parameters: BStreamEqualizerParameters(
        minDecibels: (parameters['minDecibels'] as num?)?.toDouble() ?? -12,
        maxDecibels: (parameters['maxDecibels'] as num?)?.toDouble() ?? 12,
        bands: List.unmodifiable(bands is List
            ? bands
                .whereType<Map<dynamic, dynamic>>()
                .map(BStreamEqualizerBand.fromMap)
            : const <BStreamEqualizerBand>[]),
      ),
    );
  }
}

class BStreamEqualizerParameters {
  const BStreamEqualizerParameters({
    required this.minDecibels,
    required this.maxDecibels,
    required this.bands,
  });
  final double minDecibels;
  final double maxDecibels;
  final List<BStreamEqualizerBand> bands;
}

class BStreamEqualizerBand {
  const BStreamEqualizerBand({
    required this.index,
    required this.centerFrequency,
    required this.gain,
    this.lowerFrequency = 0,
    this.upperFrequency = 0,
  });
  final int index;
  final double centerFrequency;
  final double gain;
  final double lowerFrequency;
  final double upperFrequency;
  factory BStreamEqualizerBand.fromMap(Map<dynamic, dynamic> map) =>
      BStreamEqualizerBand(
        index: (map['index'] as num).toInt(),
        centerFrequency: (map['centerFrequency'] as num).toDouble(),
        gain: (map['gain'] as num).toDouble(),
        lowerFrequency: (map['lowerFrequency'] as num?)?.toDouble() ?? 0,
        upperFrequency: (map['upperFrequency'] as num?)?.toDouble() ?? 0,
      );
}

/// Ten-band DSP installed in the player's decoded PCM path on Android and iOS.
/// No vendor-provided or system-wide Equalizer effect is instantiated.
class BStreamEqualizer extends AudioEffect
    with AndroidAudioEffect, DarwinAudioEffect {
  static const frequencies = bstreamEqualizerFrequencies;
  List<double> _gains = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  MethodChannel? _channel;
  String? _boundId;
  bool _supported = true;
  bool _disposed = false;
  int _revision = 0;
  int _bindingEpoch = 0;
  static const _nativeTimeout = Duration(seconds: 2);
  Future<void> _writeTail = Future<void>.value();
  final _statuses =
      StreamController<BStreamEqualizerStatus>.broadcast(sync: true);

  bool get supported => _supported;
  Stream<BStreamEqualizerStatus> get statusStream => _statuses.stream;
  @override
  String get _type => 'bstreamAudioEqualizer';

  bool get _connected =>
      !_disposed && _active && _channel != null && _boundId == _player?._id;

  BStreamEqualizerStatus _pendingStatus() {
    final active = enabled && _gains.any((gain) => gain.abs() >= .01);
    return BStreamEqualizerStatus(
      supported: _supported,
      enabled: active,
      configured: false,
      preampDb: active ? bstreamEqualizerPreampDb(_gains) : 0,
      parameters: BStreamEqualizerParameters(
        minDecibels: -12,
        maxDecibels: 12,
        bands: List.unmodifiable(List.generate(
            frequencies.length,
            (index) => BStreamEqualizerBand(
                  index: index,
                  centerFrequency: frequencies[index],
                  gain: _gains[index],
                ))),
      ),
    );
  }

  @override
  Future<void> _activate(AudioPlayerPlatform platform) async {
    if (_disposed) return;
    _channel?.setMethodCallHandler(null);
    final epoch = ++_bindingEpoch;
    // An RPC from a released native player must not hold the new lane open.
    _writeTail = Future<void>.value();
    final id = _player!._id;
    _boundId = id;
    _channel = MethodChannel('com.ryanheise.just_audio.methods.$id');
    _channel!.setMethodCallHandler((call) async {
      if (!_connected ||
          epoch != _bindingEpoch ||
          _boundId != id ||
          call.method != 'bstreamEqualizerStatusChanged') {
        return;
      }
      final status = _decode(call.arguments);
      if (!_statuses.isClosed) _statuses.add(status);
    });
    // Native init already receives the curve. Reconcile a setting changed
    // during activation, without waiting on the platform future we're building.
    try {
      await _sendConfiguration();
    } catch (_) {
      // Optional processing must never prevent this player from loading audio.
      if (!_disposed && epoch == _bindingEpoch && _connected) {
        _supported = false;
        if (!_statuses.isClosed) _statuses.add(_pendingStatus());
      }
    }
  }

  Future<BStreamEqualizerStatus> configure(
      {required bool enabled, required List<double> gainsDb}) async {
    if (_disposed) throw StateError('BStream equalizer has been disposed.');
    if (gainsDb.length != frequencies.length ||
        gainsDb.any((gain) => !gain.isFinite)) {
      throw ArgumentError('BStream equalizer requires ten finite gains.');
    }
    _gains = List.unmodifiable(gainsDb.map((gain) => gain.clamp(-12.0, 12.0)));
    _enabledSubject.add(enabled);
    final revision = ++_revision;
    if (!_connected) return _pendingStatus();
    final epoch = _bindingEpoch;
    late BStreamEqualizerStatus status;
    final operation = _writeTail.then((_) async {
      if (!_connected || epoch != _bindingEpoch || revision != _revision) {
        status = _pendingStatus();
        return;
      }
      status = await _sendConfiguration();
    });
    _writeTail = operation.catchError((Object _) {});
    await operation;
    return status;
  }

  Future<BStreamEqualizerStatus> _sendConfiguration() async {
    final epoch = _bindingEpoch;
    final id = _boundId;
    final result = await _channel!.invokeMapMethod<dynamic, dynamic>(
      'bstreamEqualizerConfigure',
      {'enabled': enabled, 'gainsDb': _gains},
    ).timeout(_nativeTimeout);
    if (!_connected || epoch != _bindingEpoch || id != _boundId) {
      return _pendingStatus();
    }
    return _decode(result);
  }

  BStreamEqualizerStatus _decode(Object? raw) {
    final status = BStreamEqualizerStatus.fromMap(raw is Map ? raw : const {});
    _supported = status.supported;
    return status;
  }

  Future<BStreamEqualizerStatus> readStatus() async {
    if (!_connected) return _pendingStatus();
    final epoch = _bindingEpoch;
    final id = _boundId;
    final result = await _channel!
        .invokeMapMethod<dynamic, dynamic>('bstreamEqualizerReadStatus')
        .timeout(_nativeTimeout);
    if (!_connected || epoch != _bindingEpoch || id != _boundId) {
      return _pendingStatus();
    }
    return _decode(result);
  }

  /// Reads silence-analysis metadata without changing equalizer state.
  /// Null means this binding has no diagnostics endpoint or is no longer active.
  Future<Map<String, dynamic>?> readSkipSilenceStatus() async {
    if (!_connected) return null;
    final epoch = _bindingEpoch;
    final id = _boundId;
    try {
      final result = await _channel!
          .invokeMapMethod<String, dynamic>('bstreamSkipSilenceReadStatus')
          .timeout(_nativeTimeout);
      if (!_connected || epoch != _bindingEpoch || id != _boundId) {
        return null;
      }
      return result;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    await configure(enabled: enabled, gainsDb: _gains);
  }

  @override
  AudioEffectMessage _toMessage() =>
      _BStreamEqualizerMessage(enabled: enabled, gains: _gains);

  @override
  Future<void> _dispose() async {
    _disposed = true;
    ++_bindingEpoch;
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _boundId = null;
    await _statuses.close();
  }
}

class _BStreamEqualizerMessage extends AudioEffectMessage {
  _BStreamEqualizerMessage({required super.enabled, required this.gains});
  final List<double> gains;
  @override
  Map<dynamic, dynamic> toMap() =>
      {'type': 'bstreamAudioEqualizer', 'enabled': enabled, 'gainsDb': gains};
}
