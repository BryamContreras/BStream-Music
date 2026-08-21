import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/base_ejs_solver.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/js_challenge.dart';

void main() {
  test('serializes solve requests and reuses cached challenges', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var playerRequests = 0;
    server.listen((request) async {
      playerRequests++;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'javascript')
        ..write('player-script');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final solver = _FakeSolver();
    addTearDown(solver.dispose);
    final playerUrl =
        'http://${server.address.address}:${server.port}/player.js';

    final results = await Future.wait([
      solver.solve(playerUrl, JSChallengeType.n, 'challenge-a'),
      solver.solve(playerUrl, JSChallengeType.n, 'challenge-a'),
    ]);

    expect(results, ['decoded-a', 'decoded-a']);
    expect(solver.executionCount, 1);
    expect(playerRequests, 1);
    expect(
      await solver.solve(playerUrl, JSChallengeType.n, 'challenge-a'),
      'decoded-a',
    );
    expect(solver.executionCount, 1);
  });

  test('rejects a non-successful player script response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..write('unavailable');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final solver = _FakeSolver();
    addTearDown(solver.dispose);
    final playerUrl =
        'http://${server.address.address}:${server.port}/player.js';

    await expectLater(
      solver.solve(playerUrl, JSChallengeType.n, 'challenge-a'),
      throwsA(isA<Exception>()),
    );
    expect(solver.executionCount, 0);
  });
}

class _FakeSolver extends BaseEJSSolver {
  var executionCount = 0;

  @override
  Future<String> executeJavaScript(String jsCode) async {
    executionCount++;
    return jsonEncode({
      'type': 'result',
      'responses': [
        {
          'type': 'result',
          'data': {'challenge-a': 'decoded-a', 'challenge-b': 'decoded-b'},
        },
      ],
    });
  }
}
