import 'dart:convert';
import 'dart:isolate';

import 'package:bstream_music/core/utils/background_work.dart';
import 'package:bstream_music/services/youtube_music/innertube_json_parser.dart';
import 'package:flutter_test/flutter_test.dart';

String? _isolateName(Object? _) => Isolate.current.debugName;
String _requireTitle(Object? value) => (value as Map)['title'] as String;
Never _fail(Object? _) => throw StateError('model failure');

class _ObservedWork {
  const _ObservedWork(this.events, {this.fail = false});
  final SendPort events;
  final bool fail;

  int parse(Object? _) {
    events.send('start');
    try {
      final watch = Stopwatch()..start();
      while (watch.elapsedMilliseconds < 30) {}
      if (fail) throw StateError('worker failure');
      return 1;
    } finally {
      events.send('end');
    }
  }

  Future<int> runAsync() async {
    final result = parse(null);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return result;
  }
}

void main() {
  test('small JSON and transforms avoid worker startup', () async {
    expect(
      await parseJsonInBackground('{}', _isolateName),
      Isolate.current.debugName,
    );
    expect(
      await transformInBackground('small', _isolateName, inputSize: 5),
      Isolate.current.debugName,
    );
  });

  test('large JSON and model reduction run in a background isolate', () async {
    final body = jsonEncode({'padding': 'x' * backgroundParsingThreshold});
    expect(
      await parseJsonInBackground(body, _isolateName),
      'BStream background work',
    );
    expect(
      await transformInBackground(body, _isolateName, inputSize: body.length),
      'BStream background work',
    );
  });

  test(
    'byte decoding preserves multi-byte text above and below threshold',
    () async {
      for (final repeats in [1, backgroundParsingThreshold]) {
        final title = '音楽 á 🩷' * repeats;
        final bytes = utf8.encode(jsonEncode({'title': title}));
        expect(await parseJsonBytesInBackground(bytes, _requireTitle), title);
        expect(await decodeUtf8InBackground(utf8.encode(title)), title);
      }
    },
  );

  test(
    'invalid UTF8, invalid JSON and model exceptions retain their types',
    () async {
      for (final padding in [0, backgroundParsingThreshold]) {
        await expectLater(
          decodeUtf8InBackground([...List.filled(padding, 32), 0xff]),
          throwsFormatException,
        );
        await expectLater(
          parseJsonBytesInBackground(
            utf8.encode('${' ' * padding}{bad'),
            decodedJsonValue,
          ),
          throwsFormatException,
        );
        await expectLater(
          parseJsonInBackground('${' ' * padding}{}', _fail),
          throwsStateError,
        );
      }
    },
  );

  test(
    'catalog and other CPU jobs share the same bounded worker queue',
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
        final job = _ObservedWork(events.sendPort);
        final failing = _ObservedWork(events.sendPort, fail: true);
        final body = '${' ' * backgroundParsingThreshold}{}';
        await Future.wait<void>([
          expectLater(runBackgroundWork(job.runAsync), completion(1)),
          expectLater(parseInnerTubeJson(body, job.parse), completion(1)),
          expectLater(
            parseJsonInBackground(body, failing.parse),
            throwsStateError,
          ),
          expectLater(parseJsonInBackground(body, job.parse), completion(1)),
          expectLater(runBackgroundWork(job.runAsync), completion(1)),
        ]).timeout(const Duration(seconds: 10));
        await Future<void>.delayed(Duration.zero);
        expect(starts, 5);
        expect(maximum, inInclusiveRange(1, 2));
        expect(active, 0);
      } finally {
        await subscription.cancel();
        events.close();
      }
    },
  );
}
