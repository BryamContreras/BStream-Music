import 'dart:async';
import 'dart:typed_data';

import '../cancellation.dart';
import '../errors.dart';
import '../events/router.dart' as router;
import '../events/types.dart';
import '../http/ua.dart';
import 'frames.dart';
import 'raw_ws.dart';

const _heartbeatInterval = Duration(seconds: 10);
const _defaultStaleTimeout = Duration(seconds: 60);

/// Connect to TikTok WSS, stream events until stopped or connection drops.
///
/// Throws [DeviceBlockedError] on DEVICE_BLOCKED handshake rejection.
/// Returns normally on clean close, stop, or stale timeout.
Future<void> connectWss({
  required String wssUrl,
  required String ttwid,
  required String roomId,
  required void Function(TikTokEvent) onEvent,
  required void Function(Object error) onError,
  required CancellationToken cancellationToken,
  void Function()? onConnected,
  void Function()? onTraffic,
  Duration connectTimeout = const Duration(seconds: 15),
  Duration staleTimeout = _defaultStaleTimeout,
  String proxy = '',
  String? userAgent,
  String? cookies,
  String? language,
  String? region,
  Set<String>? decodedMethods,
}) async {
  final ua = userAgent ?? randomUa();
  final lang = language ?? systemLanguage();
  final reg = region ?? systemRegion();
  final cookieHeader = cookies != null
      ? 'ttwid=$ttwid; $cookies'
      : 'ttwid=$ttwid';

  final headers = {
    'User-Agent': ua,
    'Cookie': cookieHeader,
    'Origin': 'https://www.tiktok.com',
    'Referer': 'https://www.tiktok.com/',
    'Accept-Language': '$lang-$reg,$lang;q=0.9',
    'Accept-Encoding': 'gzip, deflate',
    'Cache-Control': 'no-cache',
  };

  // RawWebSocket throws DeviceBlockedError directly on DEVICE_BLOCKED.
  // Proxy uses CONNECT tunnel when specified.
  final ws = await RawWebSocket.connect(
    wssUrl,
    headers: headers,
    proxy: proxy,
    timeout: connectTimeout,
    cancellationToken: cancellationToken,
  );
  if (cancellationToken.isCancelled) {
    await ws.close();
    return;
  }

  Timer? hbTimer;
  StreamSubscription<void>? cancellationSubscription;
  try {
    cancellationSubscription = cancellationToken.onCancel.listen((_) {
      unawaited(_closeQuietly(ws));
    });
    if (cancellationToken.isCancelled) return;

    // Complete protocol setup before announcing the connection. This keeps
    // the UI from claiming success if the socket closes while the initial
    // heartbeat/enter-room frames are being sent.
    ws.send(buildHeartbeat(roomId));
    ws.send(buildEnterRoom(roomId));
    if (cancellationToken.isCancelled) return;
    onConnected?.call();

    hbTimer = Timer.periodic(_heartbeatInterval, (_) {
      try {
        ws.send(buildHeartbeat(roomId));
      } on Object {
        // connection already closed
      }
    });

    await for (final data in ws.stream.timeout(
      staleTimeout,
      onTimeout: (sink) {
        sink.close();
      },
    )) {
      if (cancellationToken.isCancelled) break;

      try {
        _processFrame(
          data,
          ws,
          roomId,
          onEvent,
          onTraffic: onTraffic,
          decodedMethods: decodedMethods,
        );
      } on Object catch (err) {
        onError(err);
      }
    }
  } on Object {
    // timeout, socket error, or stream error — caller decides retry
  } finally {
    hbTimer?.cancel();
    await cancellationSubscription?.cancel();
    await _closeQuietly(ws);
  }
}

Future<void> _closeQuietly(RawWebSocket ws) async {
  try {
    await ws.close();
  } on Object {
    // already closed
  }
}

void _processFrame(
  Uint8List raw,
  RawWebSocket ws,
  String roomId,
  void Function(TikTokEvent) onEvent, {
  void Function()? onTraffic,
  Set<String>? decodedMethods,
}) {
  final frame = parsePushFrame(raw);

  if (frame.payloadType != 'msg') return;
  onTraffic?.call();

  final decompressed = decompressIfGzipped(frame.payload);
  final response = decodeTikTokResponse(
    decompressed,
    roomId,
    decodedMethods: decodedMethods,
  );

  if (response.needsAck && response.internalExt.isNotEmpty) {
    try {
      ws.send(buildAck(frame.logId, response.internalExt));
    } on Object {
      // connection closing
    }
  }

  for (final event in response.events) {
    onEvent(event);
  }
}

({List<TikTokEvent> events, Uint8List internalExt, bool needsAck})
decodeTikTokResponse(
  Uint8List raw,
  String roomId, {
  Set<String>? decodedMethods,
}) {
  final response = parseResponse(raw);
  final events = <TikTokEvent>[];
  for (final message in response.messages) {
    if (decodedMethods != null && !decodedMethods.contains(message.method)) {
      continue;
    }
    events.addAll(router.decode(message.method, message.payload, roomId));
  }
  return (
    events: events,
    internalExt: response.internalExt,
    needsAck: response.needsAck,
  );
}
