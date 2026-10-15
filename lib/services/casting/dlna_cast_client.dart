import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

const _avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
const _renderingControl = 'urn:schemas-upnp-org:service:RenderingControl:1';

class DlnaDevice {
  const DlnaDevice({
    required this.id,
    required this.name,
    required this.address,
    required this.controlUrl,
    this.renderingControlUrl,
    this.avTransportServiceType = _avTransport,
    this.renderingControlServiceType = _renderingControl,
  });

  final String id;
  final String name;
  final String address;
  final Uri controlUrl;
  final Uri? renderingControlUrl;
  final String avTransportServiceType;
  final String renderingControlServiceType;
}

class DlnaPlaybackState {
  const DlnaPlaybackState({
    this.connected = false,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration,
    this.volume = 1,
    this.error,
    this.device,
  });

  final bool connected;
  final bool playing;
  final bool buffering;
  final bool completed;
  final Duration position;
  final Duration? duration;
  final double volume;
  final String? error;
  final DlnaDevice? device;
}

typedef DlnaDiscovery = Future<List<DlnaDevice>> Function(Duration timeout);

/// Original UPnP AVTransport control point. Discovery is an explicit finite
/// M-SEARCH, not a background scanner. Polling exists only for a loaded session.
class DlnaCastClient {
  DlnaCastClient({
    this.discoveryTimeout = const Duration(seconds: 3),
    this.pollInterval = const Duration(seconds: 2),
    HttpClient Function()? httpClientFactory,
    DlnaDiscovery? discovery,
    this.allowLoopbackForTesting = false,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       // Public dependency injection keeps the callable private.
       // ignore: prefer_initializing_formals
       _discovery = discovery {
    if (pollInterval < const Duration(seconds: 1) ||
        discoveryTimeout <= Duration.zero ||
        discoveryTimeout > const Duration(seconds: 10)) {
      throw ArgumentError('Invalid DLNA network interval');
    }
  }

  final Duration discoveryTimeout;
  final Duration pollInterval;
  final bool allowLoopbackForTesting;
  final HttpClient Function() _httpClientFactory;
  final DlnaDiscovery? _discovery;
  final StreamController<DlnaPlaybackState> _states =
      StreamController.broadcast();
  final Set<HttpClient> _clients = {};
  final Set<RawDatagramSocket> _discoverySockets = {};
  DlnaDevice? _device;
  DlnaPlaybackState _state = const DlnaPlaybackState();
  Future<void> _commands = Future<void>.value();
  Future<List<DlnaDevice>>? _discovering;
  Timer? _pollTimer;
  bool _polling = false;
  bool _disposed = false;
  bool _hasPlayed = false;
  bool _observedPlayback = false;
  int _generation = 0;
  int _mediaGeneration = 0;
  int _pollFailures = 0;

  DlnaDevice? get device => _device;
  DlnaPlaybackState get state => _state;
  Stream<DlnaPlaybackState> get stateStream => _states.stream;

  Future<List<DlnaDevice>> discover() {
    _ensureAlive();
    return _discovering ??=
        (_discovery?.call(discoveryTimeout) ?? _discoverLan()).whenComplete(
          () => _discovering = null,
        );
  }

  Future<List<DlnaDevice>> _discoverLan() async {
    final locations = <Uri>{};
    final sockets = <RawDatagramSocket>[];
    final subscriptions = <StreamSubscription<RawSocketEvent>>[];
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    try {
      for (final interface in interfaces.take(8)) {
        for (final address in interface.addresses.where(_privateV4).take(1)) {
          if (_disposed) return const [];
          try {
            final socket = await RawDatagramSocket.bind(address, 0);
            sockets.add(socket);
            _discoverySockets.add(socket);
            socket.multicastHops = 2;
            socket.setRawOption(
              RawSocketOption(
                RawSocketOption.levelIPv4,
                RawSocketOption.IPv4MulticastInterface,
                Uint8List.fromList(address.rawAddress),
              ),
            );
            subscriptions.add(
              socket.listen((event) {
                if (event != RawSocketEvent.read || locations.length >= 32) {
                  return;
                }
                Datagram? packet;
                while ((packet = socket.receive()) != null) {
                  final datagram = packet!;
                  if (datagram.data.length > 8192) continue;
                  final location = locationForSsdpResponse(
                    utf8.decode(datagram.data, allowMalformed: true),
                    datagram.address,
                  );
                  if (location != null && locations.length < 32) {
                    locations.add(location);
                  }
                }
              }, onError: (_) {}),
            );
            for (final target in [
              'urn:schemas-upnp-org:device:MediaRenderer:1',
              _avTransport,
            ]) {
              final search =
                  'M-SEARCH * HTTP/1.1\r\n'
                  'HOST: 239.255.255.250:1900\r\n'
                  'MAN: "ssdp:discover"\r\nMX: 2\r\nST: $target\r\n\r\n';
              socket.send(
                utf8.encode(search),
                InternetAddress('239.255.255.250'),
                1900,
              );
            }
          } on SocketException {
            // Mobile data and VPN interfaces may disallow multicast. Continue
            // with other local interfaces, never broaden to public discovery.
          }
        }
      }
      if (sockets.isNotEmpty) await Future<void>.delayed(discoveryTimeout);
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      for (final socket in sockets) {
        _discoverySockets.remove(socket);
        socket.close();
      }
    }
    if (_disposed) return const [];
    final devices = <String, DlnaDevice>{};
    // Four requests at a time bounds descriptions, sockets, and memory.
    final descriptions = locations.toList();
    for (var i = 0; i < descriptions.length && !_disposed; i += 4) {
      final batch = descriptions.skip(i).take(4).map(_describe);
      for (final device in await Future.wait(batch)) {
        if (device != null) devices[device.id] = device;
      }
    }
    return devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<DlnaDevice?> _describe(Uri location) async {
    final client = _client();
    try {
      final request = await client
          .getUrl(location)
          .timeout(const Duration(seconds: 3));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      if (response.statusCode != HttpStatus.ok) return null;
      final xml = await _readText(response, 128 * 1024);
      return deviceFromDescription(location, xml);
    } catch (_) {
      return null;
    } finally {
      _closeClient(client);
    }
  }

  Future<void> connect(DlnaDevice device) async {
    _ensureAlive();
    final address = InternetAddress.tryParse(device.address);
    final validAddress =
        address != null &&
        (_privateV4(address) ||
            (allowLoopbackForTesting && address.isLoopback));
    if (!validAddress ||
        !_sameDeviceUrl(device.controlUrl, device.address) ||
        (device.renderingControlUrl != null &&
            !_sameDeviceUrl(device.renderingControlUrl!, device.address)) ||
        !RegExp(
          r'^urn:schemas-upnp-org:service:AVTransport:\d+$',
        ).hasMatch(device.avTransportServiceType) ||
        !RegExp(
          r'^urn:schemas-upnp-org:service:RenderingControl:\d+$',
        ).hasMatch(device.renderingControlServiceType)) {
      throw ArgumentError(
        'DLNA control endpoints must belong to the local device',
      );
    }
    if (_device != null) await disconnect();
    _generation++;
    _device = device;
    _emit(DlnaPlaybackState(connected: true, device: device));
  }

  Future<void> load({
    required Uri url,
    required String mimeType,
    required String title,
    required String artist,
    Uri? artworkUrl,
    Duration position = Duration.zero,
    bool autoplay = true,
  }) {
    if (!['http', 'https'].contains(url.scheme) || url.userInfo.isNotEmpty) {
      throw ArgumentError('DLNA requires a reachable HTTP media URL');
    }
    final mediaGeneration = ++_mediaGeneration;
    _pollTimer?.cancel();
    _hasPlayed = false;
    _observedPlayback = false;
    return _command(() async {
      if (mediaGeneration != _mediaGeneration) return;
      _emit(
        DlnaPlaybackState(
          connected: true,
          buffering: true,
          position: position,
          volume: _state.volume,
          device: _device,
        ),
      );
      await _soap('SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': url.toString(),
        'CurrentURIMetaData': _metadata(
          url,
          mimeType,
          title,
          artist,
          artworkUrl,
        ),
      });
      if (mediaGeneration != _mediaGeneration) return;
      if (autoplay) {
        await _soap('Play', {'InstanceID': '0', 'Speed': '1'});
        _hasPlayed = true;
      }
      if (position > Duration.zero) {
        // REL_TIME seeking is optional in UPnP. If unsupported, keep playing
        // from the beginning instead of leaving an otherwise healthy session.
        try {
          await _soap('Seek', {
            'InstanceID': '0',
            'Unit': 'REL_TIME',
            'Target': _time(position),
          });
        } on DlnaException {
          // Seeking is optional; the renderer can still play this track.
        }
      }
      if (mediaGeneration != _mediaGeneration) return;
      _emit(
        DlnaPlaybackState(
          connected: true,
          playing: autoplay,
          position: position,
          volume: _state.volume,
          device: _device,
        ),
      );
      _startPolling();
    });
  }

  Future<void> play() => _command(() async {
    await _soap('Play', {'InstanceID': '0', 'Speed': '1'});
    _hasPlayed = true;
    _update(playing: true, buffering: false);
    _startPolling();
  });

  Future<void> pause() => _command(() async {
    await _soap('Pause', {'InstanceID': '0'});
    _update(playing: false, buffering: false);
  });

  Future<void> stop() {
    _mediaGeneration++;
    _pollTimer?.cancel();
    _hasPlayed = false;
    return _command(() async {
      await _soap('Stop', {'InstanceID': '0'});
      _update(playing: false, buffering: false);
    });
  }

  Future<void> seek(Duration position) => _command(() async {
    await _soap('Seek', {
      'InstanceID': '0',
      'Unit': 'REL_TIME',
      'Target': _time(position),
    });
    _update(position: position);
  }, reportError: false);

  Future<void> setVolume(double volume) => _command(() async {
    final device = _device!;
    if (device.renderingControlUrl == null) {
      throw const DlnaException(
        'Remote volume is not supported by this device',
      );
    }
    final value = (volume.clamp(0, 1) * 100).round();
    await _soap('SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '$value',
    }, rendering: true);
    _update(volume: value / 100);
  }, reportError: false);

  Future<void> _command(
    Future<void> Function() operation, {
    bool reportError = true,
  }) {
    _ensureAlive();
    if (_device == null) {
      return Future.error(StateError('No DLNA device connected'));
    }
    final generation = _generation;
    final result = _commands.then((_) async {
      if (_disposed || generation != _generation) {
        throw StateError('DLNA operation cancelled');
      }
      try {
        await operation();
      } catch (error) {
        if (reportError && !_disposed && generation == _generation) {
          _update(
            error: error is DlnaException
                ? error.message
                : 'The device did not respond',
          );
        }
        rethrow;
      }
    });
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _startPolling() {
    if (_disposed || _device == null || _pollTimer?.isActive == true) return;
    _pollFailures = 0;
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    if (_polling || _disposed || _device == null) return;
    _polling = true;
    final generation = _generation;
    final mediaGeneration = _mediaGeneration;
    try {
      final transport = await _soap('GetTransportInfo', {'InstanceID': '0'});
      Map<String, String> position = const {};
      try {
        position = await _soap('GetPositionInfo', {'InstanceID': '0'});
      } on DlnaException {
        // Some renderers expose only transport status, not a media position.
      }
      if (_disposed ||
          generation != _generation ||
          mediaGeneration != _mediaGeneration) {
        return;
      }
      final transportState = transport['CurrentTransportState'];
      final currentPosition = _duration(position['RelTime']) ?? _state.position;
      final duration = _duration(position['TrackDuration']) ?? _state.duration;
      if (transportState == 'PLAYING') _observedPlayback = true;
      final rejected =
          transport['CurrentTransportStatus'] == 'ERROR_OCCURRED' ||
          (transportState == 'NO_MEDIA_PRESENT' && !_observedPlayback);
      if (rejected) {
        _pollTimer?.cancel();
        _update(
          playing: false,
          buffering: false,
          error: 'The device could not play this audio format',
        );
        return;
      }
      final stopped =
          transportState == 'STOPPED' || transportState == 'NO_MEDIA_PRESENT';
      final completed =
          stopped &&
          _hasPlayed &&
          ((_observedPlayback &&
                  (duration == null || currentPosition == Duration.zero)) ||
              (duration != null &&
                  duration > Duration.zero &&
                  currentPosition > Duration.zero &&
                  currentPosition >= duration - const Duration(seconds: 4)));
      _emit(
        DlnaPlaybackState(
          connected: true,
          playing: transportState == 'PLAYING',
          buffering: transportState == 'TRANSITIONING',
          completed: completed,
          position: currentPosition,
          duration: duration,
          volume: _state.volume,
          device: _device,
        ),
      );
      _pollFailures = 0;
      if (completed) {
        _hasPlayed = false;
        _pollTimer?.cancel();
      }
    } catch (_) {
      if (!_disposed &&
          generation == _generation &&
          mediaGeneration == _mediaGeneration &&
          ++_pollFailures >= 3) {
        _pollTimer?.cancel();
        final lostDevice = _device;
        _device = null;
        _emit(
          DlnaPlaybackState(
            device: lostDevice,
            position: _state.position,
            duration: _state.duration,
            volume: _state.volume,
            error: 'The connection to the device was lost',
          ),
        );
      }
    } finally {
      _polling = false;
    }
  }

  Future<Map<String, String>> _soap(
    String action,
    Map<String, String> arguments, {
    bool rendering = false,
  }) async {
    final device = _device;
    if (device == null || _disposed) throw StateError('DLNA session ended');
    final url = rendering ? device.renderingControlUrl! : device.controlUrl;
    final service = rendering
        ? device.renderingControlServiceType
        : device.avTransportServiceType;
    final argumentXml = arguments.entries
        .map((e) => '<${e.key}>${_escape(e.value)}</${e.key}>')
        .join();
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$service">$argumentXml</u:$action></s:Body></s:Envelope>';
    final client = _client();
    try {
      final request = await client
          .postUrl(url)
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'text/xml; charset="utf-8"',
      );
      request.headers.set('SOAPAction', '"$service#$action"');
      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final xml = _parseXml(await _readText(response, 128 * 1024));
      final errorCode = _text(xml, 'errorCode');
      if (response.statusCode != HttpStatus.ok || errorCode != null) {
        throw DlnaException(
          'DLNA $action failed${errorCode == null ? '' : ' (UPnP $errorCode)'}',
        );
      }
      final values = <String, String>{};
      for (final element in xml.descendants.whereType<XmlElement>()) {
        if (element.childElements.isEmpty) {
          values[element.name.local] = element.innerText;
        }
      }
      return values;
    } finally {
      _closeClient(client);
    }
  }

  HttpClient _client() {
    final client = _httpClientFactory();
    client.connectionTimeout = const Duration(seconds: 5);
    client.maxConnectionsPerHost = 1;
    _clients.add(client);
    return client;
  }

  void _closeClient(HttpClient client) {
    _clients.remove(client);
    client.close(force: true);
  }

  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _generation++;
    _mediaGeneration++;
    _hasPlayed = false;
    final device = _device;
    // Superseded loads must not hold disconnect behind a slow SOAP request.
    // Invalidate their callbacks and close their sockets before sending Stop.
    for (final client in _clients.toList()) {
      _closeClient(client);
    }
    _commands = Future<void>.value();
    if (device != null && !_disposed) {
      try {
        await _soap('Stop', {'InstanceID': '0'});
      } catch (_) {}
    }
    _device = null;
    for (final client in _clients.toList()) {
      _closeClient(client);
    }
    _emit(const DlnaPlaybackState());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    // Dispose is cancellation-only. Explicit disconnect performs Stop; teardown
    // must not wait five seconds on a renderer that already disappeared.
    _disposed = true;
    _generation++;
    _mediaGeneration++;
    _pollTimer?.cancel();
    _device = null;
    for (final socket in _discoverySockets.toList()) {
      socket.close();
    }
    _discoverySockets.clear();
    for (final client in _clients.toList()) {
      _closeClient(client);
    }
    await _states.close();
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('The DLNA client is disposed');
  }

  void _emit(DlnaPlaybackState state) {
    if (_disposed) return;
    _state = state;
    _states.add(state);
  }

  void _update({
    bool? playing,
    bool? buffering,
    Duration? position,
    double? volume,
    String? error,
  }) {
    _emit(
      DlnaPlaybackState(
        connected: _state.connected,
        playing: playing ?? _state.playing,
        buffering: buffering ?? _state.buffering,
        position: position ?? _state.position,
        duration: _state.duration,
        volume: volume ?? _state.volume,
        error: error,
        device: _device,
      ),
    );
  }

  static Uri? locationForSsdpResponse(String response, InternetAddress sender) {
    if (!_privateV4(sender) || !response.startsWith('HTTP/1.1 200')) {
      return null;
    }
    final headers = <String, String>{};
    for (final line in response.split('\r\n').skip(1)) {
      final separator = line.indexOf(':');
      if (separator > 0) {
        headers[line.substring(0, separator).toLowerCase()] = line
            .substring(separator + 1)
            .trim();
      }
    }
    final location = Uri.tryParse(headers['location'] ?? '');
    if (location == null || !_sameDeviceUrl(location, sender.address)) {
      return null;
    }
    return location;
  }

  static DlnaDevice? deviceFromDescription(Uri location, String document) {
    final address = InternetAddress.tryParse(location.host);
    if (address == null ||
        !_privateV4(address) ||
        !_sameDeviceUrl(location, address.address)) {
      return null;
    }
    final xml = _parseXml(document);
    var base = location;
    final declaredBase = _text(xml, 'URLBase');
    if (declaredBase != null && declaredBase.isNotEmpty) {
      final proposed = location.resolve(declaredBase);
      if (proposed.origin != location.origin) return null;
      base = proposed;
    }
    for (final element in xml.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'device',
    )) {
      final serviceList = _child(element, 'serviceList');
      if (serviceList == null) continue;
      XmlElement? av;
      XmlElement? rendering;
      for (final service in serviceList.childElements.where(
        (e) => e.name.local == 'service',
      )) {
        final type = _child(service, 'serviceType')?.innerText.trim() ?? '';
        if (RegExp(
          r'^urn:schemas-upnp-org:service:AVTransport:\d+$',
        ).hasMatch(type)) {
          av = service;
        }
        if (RegExp(
          r'^urn:schemas-upnp-org:service:RenderingControl:\d+$',
        ).hasMatch(type)) {
          rendering = service;
        }
      }
      if (av == null) continue;
      final controlPath = _child(av, 'controlURL')?.innerText.trim();
      if (controlPath == null || controlPath.isEmpty) continue;
      final control = base.resolve(controlPath);
      if (control.origin != location.origin) continue;
      final renderingPath = rendering == null
          ? null
          : _child(rendering, 'controlURL')?.innerText.trim();
      final renderingUrl = renderingPath == null || renderingPath.isEmpty
          ? null
          : base.resolve(renderingPath);
      if (renderingUrl != null && renderingUrl.origin != location.origin) {
        continue;
      }
      final name = _child(element, 'friendlyName')?.innerText.trim();
      final udn = _child(element, 'UDN')?.innerText.trim();
      return DlnaDevice(
        id: udn == null || udn.isEmpty ? control.toString() : udn,
        name: name == null || name.isEmpty
            ? address.address
            : name.substring(0, name.length.clamp(0, 128)),
        address: address.address,
        controlUrl: control,
        renderingControlUrl: renderingUrl,
        avTransportServiceType: _child(av, 'serviceType')!.innerText.trim(),
        renderingControlServiceType: rendering == null
            ? _renderingControl
            : _child(rendering, 'serviceType')!.innerText.trim(),
      );
    }
    return null;
  }

  static bool _sameDeviceUrl(Uri url, String address) =>
      ['http', 'https'].contains(url.scheme) &&
      url.userInfo.isEmpty &&
      url.host == address &&
      !url.hasFragment;

  static bool _privateV4(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254);
  }

  static Future<String> _readText(
    HttpClientResponse response,
    int limit,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 5))) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('Oversized DLNA XML');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static XmlDocument _parseXml(String source) {
    if (source.length > 128 * 1024 ||
        RegExp(
          r'<!\s*(DOCTYPE|ENTITY)',
          caseSensitive: false,
        ).hasMatch(source)) {
      throw const FormatException('Unsafe DLNA description');
    }
    return XmlDocument.parse(source);
  }

  static XmlElement? _child(XmlElement element, String name) {
    for (final child in element.childElements) {
      if (child.name.local == name) return child;
    }
    return null;
  }

  static String? _text(XmlDocument document, String name) {
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (element.name.local == name) return element.innerText.trim();
    }
    return null;
  }

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String _metadata(
    Uri url,
    String mime,
    String title,
    String artist,
    Uri? artwork,
  ) =>
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1"><dc:title>${_escape(title)}</dc:title>'
      '<dc:creator>${_escape(artist)}</dc:creator><upnp:artist>${_escape(artist)}</upnp:artist>'
      '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
      '${artwork == null ? '' : '<upnp:albumArtURI>${_escape(artwork.toString())}</upnp:albumArtURI>'}'
      '<res protocolInfo="http-get:*:${_escape(mime)}:*">${_escape(url.toString())}</res></item></DIDL-Lite>';

  static String _time(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 3599999);
    return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:'
        '${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  static Duration? _duration(String? value) {
    if (value == null || value == 'NOT_IMPLEMENTED') return null;
    final match = RegExp(
      r'^(\d+):(\d{2}):(\d{2})(?:\.\d+)?$',
    ).firstMatch(value);
    if (match == null) return null;
    return Duration(
      hours: int.parse(match[1]!),
      minutes: int.parse(match[2]!),
      seconds: int.parse(match[3]!),
    );
  }
}

class DlnaException implements Exception {
  const DlnaException(this.message);
  final String message;
  @override
  String toString() => message;
}
