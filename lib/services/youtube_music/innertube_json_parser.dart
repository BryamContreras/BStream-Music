import 'dart:convert';

import '../../core/utils/background_work.dart';
import 'innertube_exceptions.dart';

const innerTubeBackgroundParseThreshold = backgroundParsingThreshold;

/// Decodes and reduces large responses away from the UI isolate. Only the
/// requested result returns, not an entire browse tree when a parser is given.
///
/// [parse] must be a pure top-level function or a sendable parser object's
/// tear-off, never a closure capturing a service/transport or widget. Small
/// responses avoid isolate startup; at most two large jobs run concurrently.
Future<T> parseInnerTubeJson<T>(String body, T Function(Object?) parse) async {
  if (body.length < innerTubeBackgroundParseThreshold) {
    return _parseJson(body, parse);
  }
  return _parseInWorker(body, parse);
}

// Keep the isolate closure in a separate, small scope: it must not retain the
// waiting queue, a caller's HTTP client, or other accidentally captured state.
Future<T> _parseInWorker<T>(String body, T Function(Object?) parse) =>
    runBackgroundWork(
      () => _parseJson(body, parse),
      debugName: 'InnerTube JSON parser',
    );

T _parseJson<T>(String body, T Function(Object?) parse) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (error) {
    throw InnerTubeFormatException(
      'YouTube Music returned invalid JSON: ${error.message}',
    );
  }
  return parse(decoded);
}

Object? decodedInnerTubeJson(Object? value) => value;
