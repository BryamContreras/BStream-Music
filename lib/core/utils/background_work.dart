import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';

/// Avoid isolate startup for small responses. The unit is input bytes or
/// string code units, not a guarantee that an arbitrary parser is cheap.
const backgroundParsingThreshold = 32 * 1024;
const _maximumWorkers = 2;
final _waiting = Queue<Completer<void>>();
int _active = 0;

/// Shares a bounded CPU-work queue across catalog, account and lyrics tasks.
/// Workers terminate after each job; none keeps running while the app is idle.
///
/// Pass a top-level function or a data-only job's tear-off. Do not capture a
/// service, HTTP client, platform channel, widget or database connection.
Future<T> runBackgroundWork<T>(
  FutureOr<T> Function() work, {
  String debugName = 'BStream background work',
}) async {
  if (_active >= _maximumWorkers) {
    final ready = Completer<void>();
    _waiting.add(ready);
    await ready.future;
  } else {
    _active++;
  }
  try {
    return await Isolate.run<T>(work, debugName: debugName);
  } finally {
    if (_waiting.isEmpty) {
      _active--;
    } else {
      _waiting.removeFirst().complete();
    }
  }
}

Future<R> transformInBackground<T, R>(
  T input,
  R Function(T) transform, {
  required int inputSize,
}) async {
  if (inputSize < backgroundParsingThreshold) return transform(input);
  return _transformWorker(input, transform);
}

Future<R> _transformWorker<T, R>(T input, R Function(T) transform) =>
    runBackgroundWork(() => transform(input));

/// Keeps JSON decoding and model reduction together so large intermediate
/// trees need not return to the UI isolate. FormatException is preserved.
Future<T> parseJsonInBackground<T>(
  String body,
  T Function(Object?) parse,
) async {
  if (body.length < backgroundParsingThreshold) return parse(jsonDecode(body));
  return _parseJsonWorker(body, parse);
}

Future<T> _parseJsonWorker<T>(String body, T Function(Object?) parse) =>
    runBackgroundWork(() => parse(jsonDecode(body)));

Future<T> parseJsonBytesInBackground<T>(
  List<int> bytes,
  T Function(Object?) parse,
) async {
  if (bytes.length < backgroundParsingThreshold) {
    return parse(jsonDecode(utf8.decode(bytes)));
  }
  return _parseJsonBytesWorker(bytes, parse);
}

Future<T> _parseJsonBytesWorker<T>(
  List<int> bytes,
  T Function(Object?) parse,
) => runBackgroundWork(() => parse(jsonDecode(utf8.decode(bytes))));

Future<String> decodeUtf8InBackground(List<int> bytes) async {
  if (bytes.length < backgroundParsingThreshold) return utf8.decode(bytes);
  return _decodeUtf8Worker(bytes);
}

Future<String> _decodeUtf8Worker(List<int> bytes) =>
    runBackgroundWork(() => utf8.decode(bytes));

Object? decodedJsonValue(Object? value) => value;
