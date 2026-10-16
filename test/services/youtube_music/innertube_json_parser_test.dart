import 'dart:convert';
import 'dart:isolate';

import 'package:bstream_music/services/youtube_music/innertube_exceptions.dart';
import 'package:bstream_music/services/youtube_music/innertube_json_parser.dart';
import 'package:flutter_test/flutter_test.dart';

String? _isolateName(Object? _) => Isolate.current.debugName;

String _largeBody(int id) =>
    jsonEncode({'id': id, 'padding': 'x' * innerTubeBackgroundParseThreshold});

class _ObservedParser {
  const _ObservedParser(this.events);
  final SendPort events;

  int parse(Object? decoded) {
    final id = (decoded as Map)['id'] as int;
    events.send('start');
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < 40) {
      // Only the worker is busy; the test isolate must remain responsive.
    }
    events.send('end');
    return id;
  }
}

void main() {
  test('small JSON avoids creating a worker', () async {
    expect(
      await parseInnerTubeJson('{}', _isolateName),
      Isolate.current.debugName,
    );
  });

  test(
    'large JSON and its reduction run outside the calling isolate',
    () async {
      expect(
        await parseInnerTubeJson(_largeBody(1), _isolateName),
        'InnerTube JSON parser',
      );
    },
  );

  test(
    'large jobs are bounded to two concurrent workers and retain order',
    () async {
      final events = ReceivePort();
      var active = 0;
      var maximum = 0;
      var starts = 0;
      final subscription = events.listen((event) {
        active += event == 'start' ? 1 : -1;
        if (event == 'start') starts++;
        if (active > maximum) maximum = active;
      });
      try {
        final parser = _ObservedParser(events.sendPort);
        final results = await Future.wait([
          for (var id = 0; id < 6; id++)
            parseInnerTubeJson(_largeBody(id), parser.parse),
        ]);
        await Future<void>.delayed(Duration.zero);
        expect(results, [0, 1, 2, 3, 4, 5]);
        expect(starts, 6);
        expect(maximum, inInclusiveRange(1, 2));
        expect(active, 0);
      } finally {
        await subscription.cancel();
        events.close();
      }
    },
  );

  test('invalid JSON releases worker capacity for queued requests', () async {
    final invalid = '${' ' * innerTubeBackgroundParseThreshold}{invalid';
    await Future.wait([
      expectLater(
        parseInnerTubeJson(invalid, decodedInnerTubeJson),
        throwsA(isA<InnerTubeFormatException>()),
      ),
      expectLater(
        parseInnerTubeJson(invalid, decodedInnerTubeJson),
        throwsA(isA<InnerTubeFormatException>()),
      ),
      expectLater(
        parseInnerTubeJson(_largeBody(7), decodedInnerTubeJson),
        completion(containsPair('id', 7)),
      ),
    ]).timeout(const Duration(seconds: 10));
  });
}
