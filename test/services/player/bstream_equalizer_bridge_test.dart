import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio/bstream_equalizer_tuning.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'curve configured before decoder activation is retained without waiting',
    () async {
      final equalizer = BStreamEqualizer();
      final gains = <double>[3.5, -2.5, 0, 12, -12, 1, -1, 2, -2, .5];
      final status = await equalizer.configure(enabled: true, gainsDb: gains);
      gains[0] = 9;

      expect(equalizer.enabled, isTrue);
      expect(status.engine, 'bstream-dsp');
      expect(status.configured, isFalse);
      expect(status.parameters.bands.map((band) => band.gain), [
        3.5,
        -2.5,
        0,
        12,
        -12,
        1,
        -1,
        2,
        -2,
        .5,
      ]);
      expect(status.parameters.bands.map((band) => band.centerFrequency), [
        31,
        62,
        125,
        250,
        500,
        1000,
        2000,
        4000,
        8000,
        16000,
      ]);
      expect(
        status.preampDb,
        bstreamEqualizerPreampDb(
          status.parameters.bands.map((b) => b.gain).toList(),
        ),
      );
      expect((await equalizer.readStatus()).parameters.bands.first.gain, 3.5);
      expect(await equalizer.readSkipSilenceStatus(), isNull);

      final bypass = await equalizer.configure(
        enabled: false,
        gainsDb: [3.5, -2.5, 0, 12, -12, 1, -1, 2, -2, .5],
      );
      expect(bypass.enabled, isFalse);
      expect(bypass.preampDb, 0);
      expect(bypass.parameters.bands.first.gain, 3.5);
      expect(() => bypass.parameters.bands.clear(), throwsUnsupportedError);
    },
  );

  test('invalid client curves cannot reach the native processor', () async {
    final equalizer = BStreamEqualizer();
    await expectLater(
      equalizer.configure(enabled: true, gainsDb: [1, 2]),
      throwsArgumentError,
    );
    await expectLater(
      equalizer.configure(enabled: true, gainsDb: [0, 0, 0, 0, 0]),
      throwsArgumentError,
    );
    for (final invalid in [double.nan, double.infinity, -double.infinity]) {
      await expectLater(
        equalizer.configure(
          enabled: true,
          gainsDb: [0, 0, invalid, 0, 0, 0, 0, 0, 0, 0],
        ),
        throwsArgumentError,
      );
    }
    final clamped = await equalizer.configure(
      enabled: true,
      gainsDb: [99, -99, .5, -.5, 0, 0, 0, 0, 0, 0],
    );
    expect(clamped.parameters.bands.map((band) => band.gain), [
      12,
      -12,
      .5,
      -.5,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  });

  test('native diagnostics retain processed format and applied revision', () {
    final status = BStreamEqualizerStatus.fromMap({
      'supported': true,
      'enabled': true,
      'configured': true,
      'engine': 'bstream-dsp',
      'preampDb': -3.5,
      'processedFrames': 96000,
      'sampleRate': 48000,
      'channelCount': 2,
      'pcmEncoding': 4,
      'revision': 8,
      'appliedRevision': 7,
      'parameters': {
        'minDecibels': -12,
        'maxDecibels': 12,
        'bands': [
          {'index': 0, 'centerFrequency': 31, 'gain': 3.5},
        ],
      },
    });
    expect(status.supported, isTrue);
    expect(status.configured, isTrue);
    expect(status.processedFrames, 96000);
    expect(status.sampleRate, 48000);
    expect(status.channelCount, 2);
    expect(status.pcmEncoding, 4);
    expect(status.revision, 8);
    expect(status.appliedRevision, 7);
    expect(status.parameters.bands.single.gain, 3.5);
    expect(status.skipSilenceSupported, isNull);
  });

  test(
    'Darwin play intent waits for native startup before advancing its clock',
    () async {
      final bridge = _NativeBridge(darwin: true);
      final equalizer = BStreamEqualizer();
      final player = _player(equalizer, darwin: true);
      addTearDown(() async {
        await player.dispose();
        bridge.dispose();
      });
      await _load(player);
      final engine = bridge.engines.single;
      final delayed = engine.blockPlay();
      final play = player.play();
      expect(player.playing, isTrue);
      expect(player.processingState, ProcessingState.ready);
      await delayed.started.future;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(player.position, Duration.zero);

      // The native tap can genuinely buffer after accepting the play intent.
      await engine.emitPlayback(processingState: 2);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.processingState, ProcessingState.buffering);
      expect(player.position, Duration.zero);
      await engine.emitPlayback();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.processingState, ProcessingState.ready);
      expect(
        player.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 150)),
      );
      await player.pause();
      await play.timeout(const Duration(seconds: 1));
      delayed.complete({});
    },
  );

  test(
    'Darwin cancels session activation without cancelling a later resume',
    () async {
      const sessionChannel = MethodChannel('com.ryanheise.audio_session');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final activationStarted = Completer<void>();
      final activationReleased = Completer<void>();
      messenger.setMockMethodCallHandler(sessionChannel, (call) async {
        if (call.method == 'setConfiguration') {
          activationStarted.complete();
          await activationReleased.future;
        }
        return null;
      });
      final bridge = _NativeBridge(darwin: true);
      final equalizer = BStreamEqualizer();
      final player = _player(equalizer, darwin: true, activateSession: true);
      addTearDown(() async {
        if (!activationReleased.isCompleted) activationReleased.complete();
        await player.dispose();
        bridge.dispose();
        messenger.setMockMethodCallHandler(sessionChannel, null);
      });
      await _load(player);
      final engine = bridge.engines.single;
      final cancelled = player.play();
      await activationStarted.future;
      await player.pause();
      await cancelled.timeout(const Duration(seconds: 1));
      expect(engine.playCalls, 0);
      expect(player.playing, isFalse);
      expect(player.processingState, ProcessingState.ready);
      expect(player.position, Duration.zero);

      final delayed = engine.blockPlay();
      final resumed = player.play();
      await delayed.started.future;
      activationReleased.complete();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(player.playing, isTrue);
      expect(player.position, Duration.zero);
      await engine.emitPlayback();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.playing, isTrue);
      expect(
        player.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 150)),
      );
      await player.pause();
      await resumed.timeout(const Duration(seconds: 1));
      delayed.complete({});
    },
  );

  test(
    'Darwin disposal cancels native startup before awaiting cleanup',
    () async {
      final bridge = _NativeBridge(darwin: true);
      final equalizer = BStreamEqualizer();
      final player = _player(equalizer, darwin: true);
      addTearDown(() async {
        await player.dispose();
        bridge.dispose();
      });
      await _load(player);
      final engine = bridge.engines.single;
      final delayed = engine.blockPlay();
      final play = player.play();
      await delayed.started.future;

      final disposal = player.dispose();
      expect(player.playing, isFalse);
      await play.timeout(const Duration(seconds: 1));
      await disposal.timeout(const Duration(seconds: 1));
      delayed.complete({});
    },
  );

  test('a cancelled Darwin start cannot unlock the next play clock', () async {
    final bridge = _NativeBridge(darwin: true);
    final equalizer = BStreamEqualizer();
    final player = _player(equalizer, darwin: true);
    addTearDown(() async {
      await player.dispose();
      bridge.dispose();
    });
    await _load(player);
    final engine = bridge.engines.single;
    final firstReply = engine.blockPlay();
    final firstPlay = player.play();
    await firstReply.started.future;
    final oldEventTime = DateTime.now();
    await player.pause();
    await firstPlay.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final secondReply = engine.blockPlay();
    final secondPlay = player.play();
    await secondReply.started.future;
    firstReply.complete({});
    await engine.emitPlayback(updateTime: oldEventTime);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(player.playing, isTrue);
    expect(player.processingState, ProcessingState.ready);
    expect(player.position, Duration.zero);

    await engine.emitPlayback();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      player.position,
      greaterThanOrEqualTo(const Duration(milliseconds: 150)),
    );
    await player.pause();
    await secondPlay.timeout(const Duration(seconds: 1));
    secondReply.complete({});
  });

  test(
    'Darwin initializes the shared DSP and retains skip targets per asset',
    () async {
      final bridge = _NativeBridge(darwin: true);
      final equalizer = BStreamEqualizer();
      final player = _player(equalizer, darwin: true);
      addTearDown(() async {
        await player.dispose();
        bridge.dispose();
      });
      await equalizer.configure(
        enabled: true,
        gainsDb: [3.5, 1, -2, 0, 4, 1, -1, 2, -2, .5],
      );
      await player.setSkipSilenceEnabled(true);
      await _load(player);
      final request = bridge.initArguments.single;
      expect(request['androidAudioEffects'], isEmpty);
      final effects = request['darwinAudioEffects'] as List<dynamic>;
      expect(effects, hasLength(1));
      expect(effects.single, {
        'type': 'bstreamAudioEqualizer',
        'enabled': true,
        'gainsDb': [3.5, 1.0, -2.0, 0.0, 4.0, 1.0, -1.0, 2.0, -2.0, .5],
      });
      final engine = bridge.engines.single;
      expect(engine.requestedSkipSilence, isTrue);
      expect((await equalizer.readStatus()).parameters.bands.first.gain, 3.5);

      engine.skipSilenceSupported = false;
      await engine.emitStatus();
      expect((await equalizer.readStatus()).skipSilenceSupported, isFalse);
      // Unsupported current assets still acknowledge the preference. The next
      // native item receives the latest value instead of an earlier cached one.
      await player.setSkipSilenceEnabled(false);
      expect(engine.requestedSkipSilence, isFalse);
      await player.setSkipSilenceEnabled(true);
      expect(engine.requestedSkipSilence, isTrue);
      engine.skipSilenceSupported = true;
      await engine.emitStatus();
      expect((await equalizer.readStatus()).skipSilenceSupported, isTrue);
      expect(equalizer.supported, isTrue);
    },
  );

  test(
    'Darwin silence diagnostics preserve metadata without changing EQ state',
    () async {
      final bridge = _NativeBridge(darwin: true);
      final equalizer = BStreamEqualizer();
      final player = _player(equalizer, darwin: true);
      addTearDown(() async {
        await player.dispose();
        bridge.dispose();
      });
      await equalizer.configure(
        enabled: true,
        gainsDb: [3.5, 1, -2, 0, 4, 1, -1, 2, -2, .5],
      );
      await _load(player);
      final engine = bridge.engines.single;
      final revision = engine.revision;
      final nativeStatus = <String, Object?>{
        'supported': false,
        'assetReadable': false,
        'error': 'The asset is not readable.',
        'errorCode': -11800,
        'errorDomain': 'AVFoundationErrorDomain',
        'readersCreated': 0,
        'decodedFrames': 0,
        'rangeCount': 0,
        'ranges': <Object?>[],
        'lastPositionSeconds': 0.25,
        'lastBufferedUntilSeconds': 8.0,
        'lastLimitSeconds': 8.0,
      };
      engine.skipSilenceDiagnostics = nativeStatus;

      expect(await equalizer.readSkipSilenceStatus(), nativeStatus);
      expect(engine.skipSilenceReadCalls, 1);
      expect(equalizer.supported, isTrue);
      expect(equalizer.enabled, isTrue);
      expect(engine.revision, revision);
      expect(engine.gains, [3.5, 1, -2, 0, 4, 1, -1, 2, -2, .5]);
    },
  );

  test('silence diagnostics are optional on the Android bridge', () async {
    final bridge = _NativeBridge();
    final equalizer = BStreamEqualizer();
    final player = _player(equalizer);
    addTearDown(() async {
      await player.dispose();
      bridge.dispose();
    });
    await _load(player);

    expect(await equalizer.readSkipSilenceStatus(), isNull);
    expect(bridge.engines.single.skipSilenceReadCalls, 1);
    expect(equalizer.supported, isTrue);
  });

  test('silence diagnostics ignore a reply from a released binding', () async {
    final bridge = _NativeBridge(darwin: true);
    final equalizer = BStreamEqualizer();
    final player = _player(equalizer, darwin: true);
    addTearDown(() async {
      await player.dispose();
      bridge.dispose();
    });
    await _load(player);
    final oldEngine = bridge.engines.single;
    final delayed = oldEngine.blockSkipSilenceRead();
    final oldRead = equalizer.readSkipSilenceStatus();
    await delayed.started.future;
    await player.stop();
    expect(await equalizer.readSkipSilenceStatus(), isNull);
    await _load(player);
    final currentEngine = bridge.engines.last;
    currentEngine.skipSilenceDiagnostics = {'decodedFrames': 48000};

    expect(await equalizer.readSkipSilenceStatus(), {'decodedFrames': 48000});
    delayed.complete({'supported': false, 'decodedFrames': 8});
    expect(await oldRead, isNull);
    expect(equalizer.supported, isTrue);
    expect(currentEngine.skipSilenceReadCalls, 1);
  });

  test(
    'a released engine cannot block writes or overwrite a new engine ACK',
    () async {
      final bridge = _NativeBridge();
      final equalizer = BStreamEqualizer();
      final player = _player(equalizer);
      addTearDown(() async {
        await player.dispose();
        bridge.dispose();
      });
      await _load(player);
      final oldEngine = bridge.engines.single;
      final delayed = oldEngine.blockConfigure();
      final oldWrite = equalizer.configure(
        enabled: true,
        gainsDb: [6, 3, 0, 0, 0, 0, 0, 0, 0, 0],
      );
      await delayed.started.future;
      await player.stop();
      await _load(player);
      final currentEngine = bridge.engines.last;
      expect(currentEngine.id, isNot(oldEngine.id));

      // The old reply is still held: this must use a fresh native write lane,
      // rather than waiting for the retired engine's two-second timeout.
      final current = await equalizer
          .configure(enabled: true, gainsDb: [-3, 0, 2.5, 0, -1, 1, 2, 3, 4, 5])
          .timeout(const Duration(seconds: 1));
      expect(current.supported, isTrue);
      expect(current.parameters.bands.map((band) => band.gain), [
        -3,
        0,
        2.5,
        0,
        -1,
        1,
        2,
        3,
        4,
        5,
      ]);
      delayed.complete(oldEngine.status(supported: false));
      final retiredReply = await oldWrite;
      expect(equalizer.supported, isTrue);
      expect(retiredReply.supported, isTrue);
      expect(retiredReply.configured, isFalse);
      expect(retiredReply.parameters.bands.map((band) => band.gain), [
        -3,
        0,
        2.5,
        0,
        -1,
        1,
        2,
        3,
        4,
        5,
      ]);
      expect((await equalizer.readStatus()).supported, isTrue);
      expect(currentEngine.gains, [-3, 0, 2.5, 0, -1, 1, 2, 3, 4, 5]);
    },
  );

  test(
    'stale reads and callbacks cannot cross native player identities',
    () async {
      final bridge = _NativeBridge();
      final equalizer = BStreamEqualizer();
      final player = _player(equalizer);
      final statuses = <BStreamEqualizerStatus>[];
      final subscription = equalizer.statusStream.listen(statuses.add);
      addTearDown(() async {
        await subscription.cancel();
        await player.dispose();
        bridge.dispose();
      });
      await _load(player);
      final oldEngine = bridge.engines.single;
      final delayed = oldEngine.blockRead();
      final oldRead = equalizer.readStatus();
      await delayed.started.future;
      await player.stop();
      await _load(player);
      final currentEngine = bridge.engines.last;
      await equalizer.configure(
        enabled: true,
        gainsDb: [0, 0, -6, 0, 0, 0, 0, 0, 0, 0],
      );
      delayed.complete(oldEngine.status(supported: false));
      expect((await oldRead).configured, isFalse);
      expect(equalizer.supported, isTrue);

      await oldEngine.emitStatus(supported: false);
      expect(statuses, isEmpty);
      expect(equalizer.supported, isTrue);
      await currentEngine.emitStatus();
      expect(statuses, hasLength(1));
      expect(statuses.single.parameters.bands[2].gain, -6);
      expect(statuses.single.supported, isTrue);
      // Playback ready events have already traversed the separate event channel;
      // installing the equalizer's method callback must preserve that path.
      expect(player.processingState, ProcessingState.ready);
    },
  );

  test(
    'disposal ignores an in-flight read and rejects subsequent writes',
    () async {
      final bridge = _NativeBridge();
      final equalizer = BStreamEqualizer();
      final player = _player(equalizer);
      addTearDown(() async {
        await player.dispose();
        bridge.dispose();
      });
      await _load(player);
      final engine = bridge.engines.single;
      final delayed = engine.blockRead();
      final read = equalizer.readStatus();
      await delayed.started.future;
      await player.dispose();
      delayed.complete(engine.status(supported: false));
      final result = await read;
      expect(result.configured, isFalse);
      expect(equalizer.supported, isTrue);
      await expectLater(
        equalizer.configure(
          enabled: true,
          gainsDb: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        ),
        throwsStateError,
      );
    },
  );

  test('a timed-out native write does not poison later writes', () async {
    final bridge = _NativeBridge();
    final equalizer = BStreamEqualizer();
    final player = _player(equalizer);
    addTearDown(() async {
      await player.dispose();
      bridge.dispose();
    });
    await _load(player);
    final engine = bridge.engines.single;
    final delayed = engine.blockConfigure();
    final timeout = expectLater(
      equalizer.configure(
        enabled: true,
        gainsDb: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      ),
      throwsA(isA<TimeoutException>()),
    );
    await delayed.started.future;
    await timeout;
    final recovered = await equalizer
        .configure(enabled: true, gainsDb: [0, -3.5, 0, 1.5, 0, 0, 0, 0, 0, 0])
        .timeout(const Duration(seconds: 1));
    expect(recovered.parameters.bands.map((band) => band.gain), [
      0,
      -3.5,
      0,
      1.5,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    delayed.complete(engine.status(supported: false));
    await Future<void>.delayed(Duration.zero);
    expect(equalizer.supported, isTrue);
  });
}

AudioPlayer _player(
  BStreamEqualizer equalizer, {
  bool darwin = false,
  bool activateSession = false,
}) => AudioPlayer(
  audioPipeline: darwin
      ? AudioPipeline(darwinAudioEffects: [equalizer])
      : AudioPipeline(androidAudioEffects: [equalizer]),
  handleInterruptions: false,
  androidApplyAudioAttributes: false,
  handleAudioSessionActivation: activateSession,
  useProxyForRequestHeaders: false,
);

Future<Duration?> _load(AudioPlayer player) => player.setAudioSource(
  AudioSource.uri(Uri.parse('file:///bstream-bridge-fixture.wav')),
);

/// Drive the public AudioPlayer API through its real method/event codecs. Only
/// the native implementation is replaced; effect activation stays production.
class _NativeBridge {
  _NativeBridge({this.darwin = false}) {
    messenger.setMockMethodCallHandler(_main, (call) async {
      if (call.method == 'init') {
        final arguments = call.arguments as Map<dynamic, dynamic>;
        initArguments.add(arguments);
        final engine = _NativeEngine(arguments['id'] as String, this);
        final effects =
            arguments[darwin ? 'darwinAudioEffects' : 'androidAudioEffects']
                as List<dynamic>;
        final equalizer = effects.cast<Map<dynamic, dynamic>>().singleWhere(
          (effect) => effect['type'] == 'bstreamAudioEqualizer',
        );
        engine.enabled = equalizer['enabled'] == true;
        engine.gains = (equalizer['gainsDb'] as List<dynamic>)
            .map((gain) => (gain as num).toDouble())
            .toList();
        engines.add(engine);
        install(engine.methods, engine.handle);
        install(engine.events, (_) async => null);
        install(engine.data, (_) async => null);
        return null;
      }
      if (call.method == 'disposePlayer' ||
          call.method == 'disposeAllPlayers') {
        return <String, Object?>{};
      }
      throw StateError('Unexpected native player method: ${call.method}');
    });
  }

  static const _main = MethodChannel('com.ryanheise.just_audio.methods');
  final bool darwin;
  final initArguments = <Map<dynamic, dynamic>>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final engines = <_NativeEngine>[];
  final channels = <MethodChannel>[];
  final blocked = <_BlockedReply>[];

  void install(
    MethodChannel channel,
    Future<dynamic> Function(MethodCall) handler,
  ) {
    channels.add(channel);
    messenger.setMockMethodCallHandler(channel, handler);
  }

  void dispose() {
    for (final reply in blocked) {
      reply.complete(<String, Object?>{'supported': false});
    }
    messenger.setMockMethodCallHandler(_main, null);
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  }
}

class _NativeEngine {
  _NativeEngine(this.id, this.bridge);

  final String id;
  final _NativeBridge bridge;
  bool enabled = false;
  List<double> gains = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  bool requestedSkipSilence = false;
  bool? skipSilenceSupported;
  int revision = 0;
  _BlockedReply? _configureReply;
  _BlockedReply? _readReply;
  _BlockedReply? _skipSilenceReadReply;
  _BlockedReply? _playReply;
  int playCalls = 0;
  int skipSilenceReadCalls = 0;
  Map<String, Object?> skipSilenceDiagnostics = {'supported': true};
  MethodChannel get methods =>
      MethodChannel('com.ryanheise.just_audio.methods.$id');
  MethodChannel get events =>
      MethodChannel('com.ryanheise.just_audio.events.$id');
  MethodChannel get data => MethodChannel('com.ryanheise.just_audio.data.$id');

  _BlockedReply blockConfigure() {
    final reply = _BlockedReply();
    bridge.blocked.add(reply);
    return _configureReply = reply;
  }

  _BlockedReply blockRead() {
    final reply = _BlockedReply();
    bridge.blocked.add(reply);
    return _readReply = reply;
  }

  _BlockedReply blockSkipSilenceRead() {
    final reply = _BlockedReply();
    bridge.blocked.add(reply);
    return _skipSilenceReadReply = reply;
  }

  _BlockedReply blockPlay() {
    final reply = _BlockedReply();
    bridge.blocked.add(reply);
    return _playReply = reply;
  }

  Future<dynamic> handle(MethodCall call) async {
    if (call.method == 'play') {
      playCalls++;
      final reply = _playReply;
      _playReply = null;
      if (reply != null) {
        reply.started.complete();
        return reply.result.future;
      }
      return <String, Object?>{};
    }
    if (call.method == 'setSkipSilence') {
      final arguments = call.arguments as Map<dynamic, dynamic>;
      requestedSkipSilence = arguments['enabled'] == true;
      return <String, Object?>{};
    }
    if (call.method == 'bstreamEqualizerConfigure') {
      final arguments = call.arguments as Map<dynamic, dynamic>;
      enabled = arguments['enabled'] == true;
      gains = (arguments['gainsDb'] as List<dynamic>)
          .map((gain) => (gain as num).toDouble())
          .toList();
      revision++;
      final reply = _configureReply;
      _configureReply = null;
      if (reply != null) {
        reply.started.complete();
        return reply.result.future;
      }
      return status();
    }
    if (call.method == 'bstreamEqualizerReadStatus') {
      final reply = _readReply;
      _readReply = null;
      if (reply != null) {
        reply.started.complete();
        return reply.result.future;
      }
      return status();
    }
    if (call.method == 'bstreamSkipSilenceReadStatus') {
      skipSilenceReadCalls++;
      if (!bridge.darwin) throw MissingPluginException();
      final reply = _skipSilenceReadReply;
      _skipSilenceReadReply = null;
      if (reply != null) {
        reply.started.complete();
        return reply.result.future;
      }
      return skipSilenceDiagnostics;
    }
    if (call.method == 'load') {
      await emitPlayback();
      return <String, Object?>{'duration': 180000000};
    }
    return <String, Object?>{};
  }

  Future<void> emitPlayback({int processingState = 3, DateTime? updateTime}) =>
      bridge.messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'processingState': processingState,
          'updateTime': (updateTime ?? DateTime.now()).millisecondsSinceEpoch,
          'updatePosition': 0,
          'bufferedPosition': 180000000,
          'duration': 180000000,
          'currentIndex': 0,
        }),
        null,
      );

  Future<void> emitStatus({bool supported = true}) async {
    await bridge.messenger.handlePlatformMessage(
      methods.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(
          'bstreamEqualizerStatusChanged',
          status(supported: supported),
        ),
      ),
      null,
    );
  }

  Map<String, Object?> status({bool supported = true}) => {
    if (skipSilenceSupported != null)
      'skipSilenceSupported': skipSilenceSupported,
    'supported': supported,
    'enabled': supported && enabled && gains.any((gain) => gain.abs() >= .01),
    'configured': true,
    'engine': 'bstream-dsp',
    'preampDb': enabled ? bstreamEqualizerPreampDb(gains) : 0,
    'processedFrames': 48000,
    'sampleRate': 48000,
    'channelCount': 2,
    'pcmEncoding': 2,
    'revision': revision,
    'appliedRevision': revision,
    'parameters': {
      'minDecibels': -12,
      'maxDecibels': 12,
      'bands': [
        for (
          var index = 0;
          index < BStreamEqualizer.frequencies.length;
          index++
        )
          {
            'index': index,
            'centerFrequency': BStreamEqualizer.frequencies[index],
            'gain': gains[index],
          },
      ],
    },
  };
}

class _BlockedReply {
  final started = Completer<void>();
  final result = Completer<Map<String, Object?>>();

  void complete(Map<String, Object?> status) {
    if (!result.isCompleted) result.complete(status);
  }
}
