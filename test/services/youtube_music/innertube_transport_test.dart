import 'dart:io';

import 'package:bstream_music/services/youtube_music/innertube_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports the effective URI after relative redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/start') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/final');
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('{}');
      }
      await request.response.close();
    });

    final transport = IoInnerTubeTransport();
    addTearDown(transport.close);
    final origin = Uri.parse('http://${server.address.address}:${server.port}');

    final response = await transport.get(
      origin.resolve('/start'),
      headers: const <String, String>{},
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.effectiveUri, origin.resolve('/final'));
  });
}
