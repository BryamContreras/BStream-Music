import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/casting/dlna_cast_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _description = '''<root xmlns="urn:schemas-upnp-org:device-1-0"><device>
<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>Living room &amp; TV</friendlyName><UDN>uuid:bstream-test</UDN><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/av/control</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/volume/control</controlURL></service>
</serviceList></device></root>''';

void main() {
  test('parses renderer description with relative same-origin controls', () {
    final device = DlnaCastClient.deviceFromDescription(
      Uri.parse('http://192.168.1.8:1400/device.xml'),
      _description,
    )!;
    expect(device.name, 'Living room & TV');
    expect(device.id, 'uuid:bstream-test');
    expect(device.address, '192.168.1.8');
    expect(device.controlUrl.toString(), 'http://192.168.1.8:1400/av/control');
    expect(
      device.renderingControlUrl.toString(),
      'http://192.168.1.8:1400/volume/control',
    );
  });

  test('rejects descriptions that redirect controls outside the origin', () {
    final location = Uri.parse('http://192.168.1.8/device.xml');
    expect(
      DlnaCastClient.deviceFromDescription(
        location,
        _description.replaceFirst(
          '/av/control',
          'http://public.invalid/control',
        ),
      ),
      isNull,
    );
    expect(
      DlnaCastClient.deviceFromDescription(
        location,
        _description.replaceFirst(
          '<device>',
          '<URLBase>http://192.168.1.9/</URLBase><device>',
        ),
      ),
      isNull,
    );
    expect(
      DlnaCastClient.deviceFromDescription(
        Uri.parse('https://public.invalid/device.xml'),
        _description,
      ),
      isNull,
    );
    expect(
      () => DlnaCastClient.deviceFromDescription(
        location,
        '<!DOCTYPE root [<!ENTITY x "expanded">]>$_description',
      ),
      throwsFormatException,
    );
  });

  test('SSDP only accepts private sender with matching literal LOCATION', () {
    final sender = InternetAddress('192.168.1.8');
    const good =
        'HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.8:1400/device.xml\r\n\r\n';
    expect(DlnaCastClient.locationForSsdpResponse(good, sender)?.port, 1400);
    expect(
      DlnaCastClient.locationForSsdpResponse(
        good.replaceFirst('192.168.1.8:', '192.168.1.9:'),
        sender,
      ),
      isNull,
    );
    expect(
      DlnaCastClient.locationForSsdpResponse(good, InternetAddress('8.8.8.8')),
      isNull,
    );
    expect(
      DlnaCastClient.locationForSsdpResponse(
        good.replaceFirst('HTTP/1.1 200', 'NOTIFY * HTTP/1.1'),
        sender,
      ),
      isNull,
    );
  });

  test(
    'discovery is lazy, deduplicates simultaneous requests, and is finite',
    () async {
      var calls = 0;
      final gate = Completer<List<DlnaDevice>>();
      final client = DlnaCastClient(
        discovery: (timeout) {
          calls++;
          expect(timeout, const Duration(seconds: 3));
          return gate.future;
        },
      );
      addTearDown(client.dispose);
      expect(calls, 0);
      final first = client.discover();
      final second = client.discover();
      expect(calls, 1);
      gate.complete([]);
      expect(await first, isEmpty);
      expect(await second, isEmpty);
      expect(calls, 1);
    },
  );

  group('SOAP transport with a deterministic LAN renderer double', () {
    late HttpServer server;
    late DlnaCastClient client;
    late List<({String action, String body})> commands;
    var transportState = 'PLAYING';
    var failAction = '';

    setUp(() async {
      commands = [];
      transportState = 'PLAYING';
      failAction = '';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final action = request.headers
            .value('soapaction')!
            .replaceAll('"', '')
            .split('#')
            .last;
        final body = await utf8.decoder.bind(request).join();
        commands.add((action: action, body: body));
        String values = '';
        if (action == 'GetTransportInfo') {
          values =
              '<CurrentTransportState>$transportState</CurrentTransportState>';
        }
        if (action == 'GetPositionInfo') {
          values =
              '<TrackDuration>00:03:20</TrackDuration><RelTime>00:03:19</RelTime>';
        }
        final failed = action == failAction;
        request.response.statusCode = failed ? 500 : 200;
        request.response.headers.contentType = ContentType('text', 'xml');
        request.response.write(
          '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body>${failed ? '<s:Fault><detail><UPnPError><errorCode>701</errorCode></UPnPError></detail></s:Fault>' : '<u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">$values</u:${action}Response>'}'
          '</s:Body></s:Envelope>',
        );
        await request.response.close();
      });
      client = DlnaCastClient(
        allowLoopbackForTesting: true,
        pollInterval: const Duration(seconds: 1),
      );
      await client.connect(
        DlnaDevice(
          id: 'fake',
          name: 'Test renderer',
          address: '127.0.0.1',
          controlUrl: Uri.parse('http://127.0.0.1:${server.port}/av'),
          renderingControlUrl: Uri.parse(
            'http://127.0.0.1:${server.port}/volume',
          ),
        ),
      );
    });
    tearDown(() async {
      await client.dispose();
      await server.close(force: true);
    });

    test('loads escaped metadata and preserves command order', () async {
      await client.load(
        url: Uri.parse('http://192.168.1.5/media/token?x=1&y=2'),
        mimeType: 'audio/webm',
        title: 'Song <love> & joy',
        artist: 'A & B',
        artworkUrl: Uri.parse('https://image.example/art.jpg'),
        position: const Duration(seconds: 42),
      );
      expect(commands.map((e) => e.action), [
        'SetAVTransportURI',
        'Play',
        'Seek',
      ]);
      final soap = XmlDocument.parse(commands.first.body);
      final metadata = soap.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'CurrentURIMetaData')
          .innerText;
      final didl = XmlDocument.parse(metadata);
      expect(
        didl.descendants
            .whereType<XmlElement>()
            .firstWhere((e) => e.name.local == 'title')
            .innerText,
        'Song <love> & joy',
      );
      expect(metadata, contains('audio/webm'));
      expect(commands.last.body, contains('<Target>00:00:42</Target>'));
      expect(client.state.playing, isTrue);
    });

    test('play pause seek and volume use real SOAP commands', () async {
      await client.pause();
      await client.play();
      await client.seek(const Duration(seconds: 83));
      await client.setVolume(.37);
      await client.stop();
      expect(commands.map((e) => e.action), [
        'Pause',
        'Play',
        'Seek',
        'SetVolume',
        'Stop',
      ]);
      expect(commands[2].body, contains('<Target>00:01:23</Target>'));
      expect(commands[3].body, contains('<DesiredVolume>37</DesiredVolume>'));
      expect(client.state.volume, .37);
      expect(client.state.playing, isFalse);
    });

    test(
      'polls loaded session only and identifies natural completion',
      () async {
        expect(commands, isEmpty);
        await client.load(
          url: Uri.parse('http://192.168.1.5/token'),
          mimeType: 'audio/mp4',
          title: 'Song',
          artist: 'Artist',
        );
        final updates = <DlnaPlaybackState>[];
        final subscription = client.stateStream.listen(updates.add);
        addTearDown(subscription.cancel);
        transportState = 'STOPPED';
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        expect(commands.map((e) => e.action), [
          'SetAVTransportURI',
          'Play',
          'GetTransportInfo',
          'GetPositionInfo',
        ]);
        expect(client.state.completed, isTrue);
        expect(client.state.duration, const Duration(minutes: 3, seconds: 20));
        final count = commands.length;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(commands.length, count);
      },
    );

    test('does not report unsupported seek as a failed media load', () async {
      failAction = 'Seek';
      await client.load(
        url: Uri.parse('http://192.168.1.5/token'),
        mimeType: 'audio/mp4',
        title: 'Song',
        artist: 'Artist',
        position: const Duration(seconds: 12),
      );
      expect(client.state.playing, isTrue);
      expect(client.state.error, isNull);
    });

    test('SOAP failures are surfaced without leaking media URLs', () async {
      failAction = 'Play';
      await expectLater(client.play(), throwsA(isA<DlnaException>()));
      expect(client.state.error, 'DLNA Play failed (UPnP 701)');
      expect(client.state.error, isNot(contains('127.0.0.1')));
    });

    test('disconnect stops playback and ends polling', () async {
      await client.load(
        url: Uri.parse('http://192.168.1.5/token'),
        mimeType: 'audio/mp4',
        title: 'Song',
        artist: 'Artist',
      );
      await client.disconnect();
      expect(commands.last.action, 'Stop');
      expect(client.state.connected, isFalse);
      expect(client.device, isNull);
      final count = commands.length;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(commands.length, count);
    });

    test(
      'rejects control endpoints not belonging to the discovered device',
      () async {
        await expectLater(
          client.connect(
            DlnaDevice(
              id: 'bad',
              name: 'bad',
              address: '127.0.0.1',
              controlUrl: Uri.parse('http://public.invalid/control'),
            ),
          ),
          throwsArgumentError,
        );
        expect(client.device!.id, 'fake');
      },
    );
  });
}
