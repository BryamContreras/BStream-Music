import 'dart:async';
import 'dart:io';

import 'package:bstream_music/services/casting/cast_coordinator.dart';
import 'package:bstream_music/services/casting/dlna_cast_client.dart';
import 'package:bstream_music/services/casting/media_cast_relay.dart';
import 'package:bstream_music/services/casting/native_cast_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _speaker = CastDevice(
  id: 'receiver-1',
  name: 'Living room',
  protocol: CastProtocol.googleCast,
  address: '192.168.1.8',
);

void main() {
  late _Harness harness;
  setUp(() {
    harness = _Harness();
  });
  tearDown(() async {
    await harness.dispose();
  });

  test('construction does not initialize, discover or create a relay', () {
    expect(harness.native.initializations, 0);
    expect(harness.native.discoveryStarts, 0);
    expect(harness.dlna.discoveries, 0);
    expect(harness.relay.sources, isEmpty);
    expect(harness.coordinator.state.connected, isFalse);
  });

  test(
    'discovery starts only on request and publishes native routes',
    () async {
      await harness.coordinator.startDiscovery();
      expect(harness.native.discoveryStarts, 1);
      expect(harness.dlna.discoveries, 1);
      expect(harness.coordinator.state.devices.single.id, _speaker.id);
      expect(harness.coordinator.state.googleCastSupported, isTrue);
      await harness.coordinator.stopDiscovery();
      expect(harness.native.discoveryStops, 1);
      expect(harness.coordinator.state.discovering, isFalse);
      expect(harness.relay.sources, isEmpty);
    },
  );

  test('missing Google services does not block DLNA discovery', () async {
    harness.native.available = false;
    final dlnaDevice = _DlnaDevice();
    harness.dlna.devices = [dlnaDevice];
    await harness.coordinator.startDiscovery();
    expect(harness.coordinator.state.googleCastSupported, isFalse);
    expect(
      harness.coordinator.state.devices.single.protocol,
      CastProtocol.dlna,
    );
    expect(
      harness.coordinator.state.devices.single.dlnaDevice,
      same(dlnaDevice),
    );
    expect(harness.coordinator.state.error, isNull);
  });

  test(
    'closing discovery ignores an in-flight DLNA discovery result',
    () async {
      harness.dlna.discoveryGate = Completer<List<DlnaDevice>>();
      final discovery = harness.coordinator.startDiscovery();
      await harness.coordinator.stopDiscovery();
      harness.dlna.discoveryGate!.complete([_DlnaDevice()]);
      await discovery;
      expect(harness.coordinator.state.discovering, isFalse);
      expect(
        harness.coordinator.state.devices.every(
          (device) => device.protocol == CastProtocol.googleCast,
        ),
        isTrue,
      );
    },
  );

  test('load relays exact source and forwards logical occurrence ID', () async {
    await harness.coordinator.connect(_speaker);
    await harness.load('bstream-1');
    expect(
      harness.relay.sources.single,
      Uri.parse('https://media.example/audio.m4a'),
    );
    expect(harness.native.loads.single.contentId, 'bstream-1');
    expect(harness.native.loads.single.url.host, '192.168.1.5');
    expect(harness.coordinator.state.contentId, 'bstream-1');
    expect(harness.coordinator.state.status, CastPlaybackStatus.playing);
  });

  test(
    'default Google Cast uses header-free HTTPS directly with its actual MIME',
    () async {
      await harness.dispose();
      harness = _Harness(preferDirectRemote: null);
      await harness.coordinator.connect(_speaker);
      final source = Uri.parse('https://media.example/audio.webm');
      await harness.load('direct', source: source, mimeType: 'audio/webm');
      expect(harness.relay.sources, isEmpty);
      expect(harness.native.loads.single.url, source);
      expect(harness.native.loads.single.mimeType, 'audio/webm');
      expect(harness.coordinator.state.contentId, 'direct');
    },
  );

  test(
    'failed direct load retries one relay without stale authorization headers',
    () async {
      await harness.dispose();
      harness = _Harness(preferDirectRemote: true);
      await harness.coordinator.connect(_speaker);
      await harness.load(
        'authenticated',
        headers: {'Authorization': 'Bearer previous-song'},
      );
      expect(harness.relay.headers.last, {
        'Authorization': 'Bearer previous-song',
      });
      harness.native.failNextLoads = 1;
      final loadsBefore = harness.native.loads.length;
      final relayBefore = harness.relay.sources.length;
      await harness.load(
        'fallback',
        source: Uri.parse('https://media.example/next.aac'),
        mimeType: 'audio/aac',
      );
      expect(harness.native.loads.length - loadsBefore, 2);
      expect(harness.relay.sources.length - relayBefore, 1);
      expect(harness.relay.headers.last, isEmpty);
      expect(harness.native.loads.last.url.host, '192.168.1.5');
      expect(harness.native.loads.last.mimeType, 'audio/aac');
      expect(harness.coordinator.state.contentId, 'fallback');
    },
  );

  test(
    'headers-bound media always uses relay even with direct preference',
    () async {
      await harness.dispose();
      harness = _Harness(preferDirectRemote: true);
      await harness.coordinator.connect(_speaker);
      await harness.load(
        'authenticated',
        headers: {'Cookie': 'session=private'},
      );
      expect(harness.native.loads.length, 1);
      expect(harness.native.loads.single.url.host, '192.168.1.5');
      expect(harness.relay.headers.single, {'Cookie': 'session=private'});
    },
  );

  test(
    'previous occurrence native status cannot complete the new song',
    () async {
      await harness.coordinator.connect(_speaker);
      await harness.load('bstream-1');
      await harness.load('bstream-2');
      harness.native.emitStatus(
        'bstream-1',
        NativeCastStatus.completed,
        position: const Duration(seconds: 199),
      );
      expect(harness.coordinator.state.contentId, 'bstream-2');
      expect(harness.coordinator.state.status, CastPlaybackStatus.playing);
      expect(harness.coordinator.state.position, Duration.zero);
      harness.native.emitStatus(
        'bstream-2',
        NativeCastStatus.paused,
        position: const Duration(seconds: 7),
      );
      expect(harness.coordinator.state.status, CastPlaybackStatus.paused);
      expect(harness.coordinator.state.position, const Duration(seconds: 7));
    },
  );

  test(
    'slow obsolete relay preparation never loads over a newer song',
    () async {
      await harness.coordinator.connect(_speaker);
      harness.relay.preparationGates['slow'] = Completer<Uri>();
      final obsolete = harness.load(
        'old',
        source: Uri.parse('https://media.example/slow'),
      );
      final obsoleteResult = expectLater(obsolete, throwsStateError);
      await harness.load(
        'new',
        source: Uri.parse('https://media.example/fast'),
      );
      harness.relay.preparationGates['slow']!.complete(
        Uri.parse('http://192.168.1.5/old'),
      );
      await obsoleteResult;
      expect(harness.native.loads.map((load) => load.contentId), ['new']);
      expect(harness.coordinator.state.contentId, 'new');
      expect(harness.coordinator.state.status, CastPlaybackStatus.playing);
    },
  );

  test(
    'disconnect invalidates an awaiting preparation and stops the relay',
    () async {
      await harness.coordinator.connect(_speaker);
      harness.relay.preparationGates['slow'] = Completer<Uri>();
      final pending = harness.load(
        'old',
        source: Uri.parse('https://media.example/slow'),
      );
      final pendingResult = expectLater(pending, throwsStateError);
      await harness.coordinator.disconnect();
      harness.relay.preparationGates['slow']!.complete(
        Uri.parse('http://192.168.1.5/old'),
      );
      await pendingResult;
      expect(harness.native.loads, isEmpty);
      expect(harness.coordinator.state.connected, isFalse);
      expect(harness.coordinator.state.contentId, isNull);
      expect(harness.relay.stops, greaterThan(0));
    },
  );

  test(
    'stop invalidates awaiting load and retains connected idle receiver',
    () async {
      await harness.coordinator.connect(_speaker);
      harness.relay.preparationGates['slow'] = Completer<Uri>();
      final pending = harness.load(
        'old',
        source: Uri.parse('https://media.example/slow'),
      );
      final pendingResult = expectLater(pending, throwsStateError);
      await harness.coordinator.stop();
      harness.relay.preparationGates['slow']!.complete(
        Uri.parse('http://192.168.1.5/old'),
      );
      await pendingResult;
      expect(harness.native.loads, isEmpty);
      expect(harness.coordinator.state.connected, isTrue);
      expect(harness.coordinator.state.status, CastPlaybackStatus.idle);
      expect(harness.coordinator.state.contentId, isNull);
    },
  );

  test('late receiver completion after stop is ignored', () async {
    await harness.coordinator.connect(_speaker);
    await harness.load('bstream-1');
    await harness.coordinator.stop();
    harness.native.emitStatus('bstream-1', NativeCastStatus.completed);
    expect(harness.coordinator.state.status, CastPlaybackStatus.idle);
    expect(harness.coordinator.state.contentId, isNull);
  });
  test(
    'temporary session suspension preserves receiver and relay until resume',
    () async {
      await harness.coordinator.connect(_speaker);
      await harness.load('bstream-1');
      final stops = harness.relay.stops;
      harness.native.publish(
        const NativeCastState(
          supported: true,
          connected: false,
          suspended: true,
          contentId: 'bstream-1',
        ),
      );
      expect(harness.coordinator.state.connected, true);
      expect(harness.coordinator.state.status, CastPlaybackStatus.loading);
      expect(harness.relay.stops, stops);
      harness.native.emitStatus(
        'bstream-1',
        NativeCastStatus.playing,
        position: const Duration(seconds: 43),
      );
      expect(harness.coordinator.state.status, CastPlaybackStatus.playing);
      expect(harness.coordinator.state.position, const Duration(seconds: 43));
    },
  );

  test('receiver loss clears selection and stops relay', () async {
    await harness.coordinator.connect(_speaker);
    await harness.load('bstream-1');
    final stopsBefore = harness.relay.stops;
    harness.native.publish(const NativeCastState(supported: true));
    expect(harness.coordinator.state.connected, isFalse);
    expect(harness.coordinator.state.contentId, isNull);
    expect(harness.relay.stops, greaterThan(stopsBefore));
  });

  test(
    'global disposal closes transports, subscriptions and relay once',
    () async {
      await harness.coordinator.connect(_speaker);
      await harness.dispose();
      expect(harness.native.disposed, isTrue);
      expect(harness.dlna.disposed, isTrue);
      expect(harness.relay.disposed, isTrue);
      expect(harness.native.events.hasListener, isFalse);
      expect(harness.dlna.events.hasListener, isFalse);
      expect(harness.relay.isRunning, isFalse);
    },
  );
}

class _Harness {
  _Harness({bool? preferDirectRemote = false}) {
    coordinator = preferDirectRemote == null
        ? CastCoordinator(nativeClient: native, dlnaClient: dlna, relay: relay)
        : CastCoordinator(
            nativeClient: native,
            dlnaClient: dlna,
            relay: relay,
            preferDirectRemote: preferDirectRemote,
          );
  }
  final native = _Native();
  final dlna = _Dlna();
  final relay = _Relay();
  late final CastCoordinator coordinator;
  bool disposed = false;
  Future<void> load(
    String id, {
    Uri? source,
    String mimeType = 'audio/mp4',
    Map<String, String> headers = const {},
  }) => coordinator.load(
    source: source ?? Uri.parse('https://media.example/audio.m4a'),
    mimeType: mimeType,
    headers: headers,
    title: 'Song',
    artist: 'Artist',
    contentId: id,
    duration: const Duration(seconds: 200),
  );
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await coordinator.dispose();
  }
}

class _Load {
  const _Load(this.url, this.contentId, this.mimeType);
  final Uri url;
  final String contentId;
  final String mimeType;
}

class _Native implements NativeCastClient {
  final events = StreamController<NativeCastState>.broadcast(sync: true);
  NativeCastState _state = const NativeCastState(supported: true);
  bool available = true;
  bool disposed = false;
  int initializations = 0;
  int discoveryStarts = 0;
  int discoveryStops = 0;
  int failNextLoads = 0;
  final loads = <_Load>[];
  @override
  Stream<NativeCastState> get changes => events.stream;
  @override
  NativeCastState get state => _state;
  void publish(NativeCastState value) {
    _state = value;
    events.add(value);
  }

  void emitStatus(
    String id,
    NativeCastStatus status, {
    Duration position = Duration.zero,
  }) => publish(
    NativeCastState(
      supported: true,
      connected: true,
      deviceId: _speaker.id,
      deviceName: _speaker.name,
      status: status,
      contentId: id,
      position: position,
      duration: const Duration(seconds: 200),
      volume: .6,
    ),
  );
  @override
  Future<void> initialize() async {
    initializations++;
  }

  @override
  Future<void> startDiscovery() async {
    discoveryStarts++;
    publish(
      NativeCastState(
        supported: available,
        devices: available
            ? const [
                NativeCastDevice(
                  id: 'receiver-1',
                  name: 'Living room',
                  address: '192.168.1.8',
                ),
              ]
            : const [],
      ),
    );
    if (!available) throw StateError('Google services missing');
  }

  @override
  Future<void> stopDiscovery() async {
    discoveryStops++;
  }

  @override
  Future<void> connect(String id) async {
    emitStatus('', NativeCastStatus.idle);
  }

  @override
  Future<void> disconnect({bool stopPlayback = true}) async {
    publish(NativeCastState(supported: available));
  }

  @override
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
    loads.add(_Load(url, contentId, mimeType));
    if (failNextLoads > 0) {
      failNextLoads--;
      throw StateError('Receiver could not access the direct URL');
    }
    emitStatus(
      contentId,
      autoplay ? NativeCastStatus.playing : NativeCastStatus.paused,
      position: position,
    );
  }

  @override
  Future<void> play() async =>
      emitStatus(_state.contentId!, NativeCastStatus.playing);
  @override
  Future<void> pause() async =>
      emitStatus(_state.contentId!, NativeCastStatus.paused);
  @override
  Future<void> stop() async {
    emitStatus(_state.contentId ?? '', NativeCastStatus.idle);
  }

  @override
  Future<void> seek(Duration position) async {
    emitStatus(_state.contentId!, _state.status, position: position);
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    await events.close();
  }
}

// Pure interface fakes: no HTTP clients, method channels, sockets or timers are
// constructed. noSuchMethod keeps unrelated DLNA implementation details out
// of the coordinator's transport/ordering tests.
class _Dlna implements DlnaCastClient {
  final events = StreamController<DlnaPlaybackState>.broadcast(sync: true);
  List<DlnaDevice> devices = [];
  Completer<List<DlnaDevice>>? discoveryGate;
  int discoveries = 0;
  bool disposed = false;
  @override
  Stream<DlnaPlaybackState> get stateStream => events.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #discover) {
      discoveries++;
      return discoveryGate?.future ?? Future<List<DlnaDevice>>.value(devices);
    }
    if (invocation.memberName == #dispose) {
      disposed = true;
      return events.close();
    }
    return Future<void>.value();
  }
}

class _DlnaDevice implements DlnaDevice {
  @override
  String get id => 'dlna-1';
  @override
  String get name => 'Network speaker';
  @override
  String get address => '192.168.1.9';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Relay implements MediaCastRelay {
  final sources = <Uri>[];
  final headers = <Map<String, String>>[];
  final preparationGates = <String, Completer<Uri>>{};
  int stops = 0;
  bool disposed = false;
  bool _running = false;
  @override
  bool get isRunning => _running;
  @override
  Future<Uri> startForRemote({
    required Uri source,
    Map<String, String> headers = const {},
    required String contentType,
    InternetAddress? receiverAddress,
  }) async {
    sources.add(source);
    this.headers.add(Map.of(headers));
    _running = true;
    final gate = preparationGates[source.path.substring(1)];
    return gate != null
        ? gate.future
        : Uri.parse('http://192.168.1.5/media/${sources.length}');
  }

  @override
  Future<Uri> startForFile({
    required String path,
    required String contentType,
    InternetAddress? receiverAddress,
  }) async {
    sources.add(Uri.file(path));
    _running = true;
    return Uri.parse('http://192.168.1.5/media/file');
  }

  @override
  Future<void> stop() async {
    stops++;
    _running = false;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _running = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
