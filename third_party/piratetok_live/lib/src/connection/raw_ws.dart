import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../cancellation.dart';
import '../errors.dart';

const _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const _maximumUpgradeHeaderBytes = 64 * 1024;
const _maximumFramePayloadBytes = 16 * 1024 * 1024;

/// Raw WebSocket client — bypasses dart:io's WebSocket for full frame control.
///
/// Implements RFC 6455 framing: masking, Ping/Pong, fragmentation, Close
/// handshake. Uses a single-subscription state machine on the TLS socket to
/// handle both the HTTP upgrade and subsequent WebSocket frames.
class RawWebSocket {
  final Socket _socket;
  final _events = StreamController<Uint8List>();
  var _buf = <int>[];
  Uint8List? _fragBuf;
  bool _closed = false;

  /// Close code from server (available after stream ends).
  int? closeCode;

  /// Close reason from server (available after stream ends).
  String? closeReason;

  RawWebSocket._(this._socket);

  /// Stream of binary messages received from the server.
  Stream<Uint8List> get stream => _events.stream;

  /// Connect to a WSS URL via manual TLS + HTTP upgrade.
  ///
  /// When [proxy] is non-empty, opens a CONNECT tunnel through the proxy
  /// before upgrading to TLS + WebSocket. Supports http:// and https:// proxies.
  ///
  /// Throws [DeviceBlockedError] on DEVICE_BLOCKED handshake rejection.
  /// Throws [SocketException] on connection or upgrade failure.
  static Future<RawWebSocket> connect(
    String url, {
    Map<String, String>? headers,
    String proxy = '',
    Duration timeout = const Duration(seconds: 15),
    CancellationToken? cancellationToken,
  }) async {
    final uri = Uri.parse(url);
    final host = uri.host;
    final socket = proxy.isNotEmpty
        ? await _connectViaProxy(proxy, host, timeout)
        : await SecureSocket.connect(host, 443, timeout: timeout);
    if (cancellationToken?.isCancelled ?? false) {
      socket.destroy();
      throw const SocketException('WebSocket connection cancelled.');
    }
    final cancellationSubscription = cancellationToken?.onCancel.listen((_) {
      socket.destroy();
    });
    if (cancellationToken?.isCancelled ?? false) {
      await cancellationSubscription?.cancel();
      socket.destroy();
      throw const SocketException('WebSocket connection cancelled.');
    }

    final rng = Random();
    final wsKey = base64Encode(List.generate(16, (_) => rng.nextInt(256)));
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

    final req = StringBuffer()
      ..write('GET $path HTTP/1.1\r\n')
      ..write('Host: $host\r\n')
      ..write('Upgrade: websocket\r\n')
      ..write('Connection: Upgrade\r\n')
      ..write('Sec-WebSocket-Key: $wsKey\r\n')
      ..write('Sec-WebSocket-Version: 13\r\n');
    headers?.forEach((k, v) => req.write('$k: $v\r\n'));
    req.write('\r\n');

    try {
      socket.write(req.toString());
      await socket.flush().timeout(timeout);
    } on Object {
      await cancellationSubscription?.cancel();
      socket.destroy();
      rethrow;
    }

    // Single listener with state machine: HTTP upgrade → WS frames.
    final ws = RawWebSocket._(socket);
    var upgrading = true;
    final hdrBuf = <int>[];
    final ready = Completer<void>();

    socket.listen(
      (chunk) {
        if (upgrading) {
          hdrBuf.addAll(chunk);
          if (hdrBuf.length > _maximumUpgradeHeaderBytes) {
            socket.destroy();
            if (!ready.isCompleted) {
              ready.completeError(
                const SocketException('ws upgrade headers are too large'),
              );
            }
            return;
          }
          final str = utf8.decode(hdrBuf, allowMalformed: true);
          final idx = str.indexOf('\r\n\r\n');
          if (idx < 0) return; // need more header bytes

          upgrading = false;
          final statusLine = str.substring(0, str.indexOf('\r\n'));

          if (!RegExp(r'^HTTP/1\.[01] 101(?: |$)').hasMatch(statusLine)) {
            socket.destroy();
            if (str.contains('DEVICE_BLOCKED') || statusLine.contains('415')) {
              ready.completeError(const DeviceBlockedError());
            } else {
              ready.completeError(
                SocketException('ws upgrade rejected: $statusLine'),
              );
            }
            return;
          }

          final expectedAccept = base64Encode(
            sha1.convert(utf8.encode('$wsKey$_webSocketGuid')).bytes,
          );
          final responseHeaders = <String, String>{};
          for (final line in str.substring(0, idx).split('\r\n').skip(1)) {
            final separator = line.indexOf(':');
            if (separator > 0) {
              responseHeaders[line
                  .substring(0, separator)
                  .trim()
                  .toLowerCase()] = line
                  .substring(separator + 1)
                  .trim();
            }
          }
          if (responseHeaders['sec-websocket-accept'] != expectedAccept) {
            socket.destroy();
            ready.completeError(
              const SocketException('invalid Sec-WebSocket-Accept header'),
            );
            return;
          }

          // Any bytes after \r\n\r\n are the first WS frame data.
          final end = idx + 4;
          if (end < hdrBuf.length) {
            ws._buf.addAll(hdrBuf.sublist(end));
            try {
              ws._drain();
            } on Object catch (error, stackTrace) {
              socket.destroy();
              if (!ws._events.isClosed) {
                ws._events.addError(error, stackTrace);
                unawaited(ws._events.close());
              }
            }
          }
          ready.complete();
        } else {
          ws._buf.addAll(chunk);
          try {
            ws._drain();
          } on Object catch (error, stackTrace) {
            socket.destroy();
            if (!ws._events.isClosed) {
              ws._events.addError(error, stackTrace);
              unawaited(ws._events.close());
            }
          }
        }
      },
      onError: (Object e) {
        if (!ready.isCompleted) {
          ready.completeError(e);
        } else if (!ws._events.isClosed) {
          ws._events.addError(e);
          unawaited(ws._events.close());
        }
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(
            const SocketException('connection closed during ws upgrade'),
          );
        }
        if (!ws._events.isClosed) ws._events.close();
      },
    );

    try {
      await ready.future.timeout(timeout);
      if (cancellationToken?.isCancelled ?? false) {
        throw const SocketException('WebSocket connection cancelled.');
      }
      return ws;
    } on Object {
      socket.destroy();
      rethrow;
    } finally {
      await cancellationSubscription?.cancel();
    }
  }

  /// Open a CONNECT tunnel through an HTTP proxy, then upgrade to TLS.
  static Future<SecureSocket> _connectViaProxy(
    String proxyUrl,
    String targetHost,
    Duration timeout,
  ) async {
    final proxyUri = Uri.parse(proxyUrl);
    final proxyHost = proxyUri.host;
    final proxyPort = proxyUri.hasPort ? proxyUri.port : 8080;

    final plain = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
    try {
      plain.write(
        'CONNECT $targetHost:443 HTTP/1.1\r\n'
        'Host: $targetHost:443\r\n\r\n',
      );
      await plain.flush().timeout(timeout);
    } on Object {
      plain.destroy();
      rethrow;
    }

    // Read CONNECT response. The proxy sends a short HTTP response then the
    // tunnel is established. We listen chunk-by-chunk until we see \r\n\r\n.
    final buf = <int>[];
    final done = Completer<void>();
    final sub = plain.listen(
      (chunk) {
        buf.addAll(chunk);
        if (buf.length > _maximumUpgradeHeaderBytes) {
          plain.destroy();
          if (!done.isCompleted) {
            done.completeError(
              const SocketException('proxy CONNECT headers are too large'),
            );
          }
          return;
        }
        if (utf8.decode(buf, allowMalformed: true).contains('\r\n\r\n')) {
          if (!done.isCompleted) done.complete();
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.completeError(
            const SocketException('proxy closed before CONNECT response'),
          );
        }
      },
    );

    try {
      await done.future.timeout(timeout);
    } on Object {
      plain.destroy();
      rethrow;
    } finally {
      await sub.cancel();
    }

    final status = utf8.decode(buf, allowMalformed: true);
    if (!RegExp(r'^HTTP/1\.[01] 200(?: |$)').hasMatch(status)) {
      plain.destroy();
      throw SocketException(
        'proxy CONNECT failed: '
        '${status.split('\r\n').first}',
      );
    }

    try {
      return await SecureSocket.secure(
        plain,
        host: targetHost,
      ).timeout(timeout);
    } on Object {
      plain.destroy();
      rethrow;
    }
  }

  /// Send a binary message.
  void send(Uint8List data) {
    if (_closed) {
      throw const SocketException('WebSocket is closed.');
    }
    _writeFrame(0x02, data);
  }

  /// Close the connection with the given status code.
  Future<void> close([int code = 1000]) async {
    if (_closed) return;
    _closed = true;
    final cp = Uint8List(2);
    cp[0] = (code >> 8) & 0xFF;
    cp[1] = code & 0xFF;
    try {
      _writeFrame(0x08, cp);
      await _socket.flush().timeout(const Duration(seconds: 2));
    } on Object {
      // socket already closed
    } finally {
      _socket.destroy();
      if (!_events.isClosed) {
        await _events.close();
      }
    }
  }

  /// Write a masked WebSocket frame (RFC 6455 section 5.2).
  void _writeFrame(int opcode, Uint8List payload) {
    final buf = BytesBuilder();

    // Byte 0: FIN=1, RSV=000, opcode
    buf.addByte(0x80 | (opcode & 0x0F));

    // Byte 1+: MASK=1, payload length
    final n = payload.length;
    if (n < 126) {
      buf.addByte(0x80 | n);
    } else if (n < 65536) {
      buf.addByte(0x80 | 126);
      buf.addByte((n >> 8) & 0xFF);
      buf.addByte(n & 0xFF);
    } else {
      buf.addByte(0x80 | 127);
      for (var i = 56; i >= 0; i -= 8) {
        buf.addByte((n >> i) & 0xFF);
      }
    }

    // 4-byte masking key
    final rng = Random();
    final mask = Uint8List(4);
    for (var i = 0; i < 4; i++) {
      mask[i] = rng.nextInt(256);
    }
    buf.add(mask);

    // XOR-masked payload
    final masked = Uint8List(n);
    for (var i = 0; i < n; i++) {
      masked[i] = payload[i] ^ mask[i & 3];
    }
    buf.add(masked);

    _socket.add(buf.toBytes());
  }

  /// Parse all complete WebSocket frames from [_buf].
  void _drain() {
    while (_buf.length >= 2) {
      final b0 = _buf[0];
      final b1 = _buf[1];
      final fin = (b0 & 0x80) != 0;
      if ((b0 & 0x70) != 0) {
        throw const FormatException('Unsupported WebSocket RSV bits.');
      }
      final op = b0 & 0x0F;
      final hasMask = (b1 & 0x80) != 0;
      var pLen = b1 & 0x7F;
      var hLen = 2;

      if (pLen == 126) {
        if (_buf.length < 4) return;
        pLen = (_buf[2] << 8) | _buf[3];
        hLen = 4;
      } else if (pLen == 127) {
        if (_buf.length < 10) return;
        pLen = 0;
        for (var i = 0; i < 8; i++) {
          pLen = (pLen << 8) | _buf[2 + i];
        }
        hLen = 10;
      }

      if (hasMask) hLen += 4;
      if (pLen > _maximumFramePayloadBytes) {
        throw const FormatException('WebSocket frame payload is too large.');
      }
      if (op >= 0x08 && (!fin || pLen > 125)) {
        throw const FormatException('Invalid WebSocket control frame.');
      }
      if (_buf.length < hLen + pLen) return; // incomplete frame

      // Extract + unmask payload
      Uint8List payload;
      if (hasMask) {
        final mo = hLen - 4;
        payload = Uint8List(pLen);
        for (var i = 0; i < pLen; i++) {
          payload[i] = _buf[hLen + i] ^ _buf[mo + (i & 3)];
        }
      } else {
        payload = Uint8List.fromList(_buf.sublist(hLen, hLen + pLen));
      }
      _buf = _buf.sublist(hLen + pLen);

      // Dispatch by opcode
      switch (op) {
        case 0x00: // continuation frame
          if (_fragBuf != null) {
            final prev = _fragBuf!;
            if (prev.length + payload.length > _maximumFramePayloadBytes) {
              throw const FormatException(
                'Fragmented WebSocket message is too large.',
              );
            }
            final combined = Uint8List(prev.length + payload.length)
              ..setAll(0, prev)
              ..setRange(prev.length, prev.length + payload.length, payload);
            if (fin) {
              _events.add(combined);
              _fragBuf = null;
            } else {
              _fragBuf = combined;
            }
          }
        case 0x01: // text — treat as binary
          if (fin) {
            _events.add(payload);
          } else {
            _fragBuf = payload;
          }
        case 0x02: // binary
          if (fin) {
            _events.add(payload);
          } else {
            _fragBuf = payload;
          }
        case 0x08: // close
          if (payload.length >= 2) {
            closeCode = (payload[0] << 8) | payload[1];
            if (payload.length > 2) {
              closeReason = utf8.decode(
                payload.sublist(2),
                allowMalformed: true,
              );
            }
          }
          // Echo Close frame back per RFC 6455 section 7.1
          if (!_closed) {
            _closed = true;
            try {
              _writeFrame(0x08, payload);
            } on Object {
              // socket may be gone
            }
            _socket.destroy();
          }
          if (!_events.isClosed) _events.close();
          return;
        case 0x09: // ping → auto-pong
          _writeFrame(0x0A, payload);
        default: // pong (0x0A) or unknown — ignore
          break;
      }
    }
  }
}
