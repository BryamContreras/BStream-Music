import 'dart:io';
import 'dart:typed_data';

import '../proto/codec.dart';

const int maximumDecompressedPayloadBytes = 32 * 1024 * 1024;

/// Build a heartbeat frame for the given room.
Uint8List buildHeartbeat(String roomId) {
  final hb = protoWrite((w) {
    w.writeVarintField(1, int.parse(roomId));
  });
  return _wrapFrame(payloadType: 'hb', payload: hb);
}

/// Build an enter_room frame for the given room.
Uint8List buildEnterRoom(String roomId) {
  final enter = protoWrite((w) {
    w.writeVarintField(1, int.parse(roomId)); // room_id
    w.writeVarintField(4, 12); // live_id
    w.writeStringField(5, 'audience'); // identity
    w.writeStringField(9, '0'); // filter_welcome_msg
  });
  return _wrapFrame(payloadType: 'im_enter_room', payload: enter);
}

/// Build an ack frame.
Uint8List buildAck(int logId, Uint8List internalExt) {
  return protoWrite((w) {
    w.writeVarintField(2, logId); // log_id
    w.writeStringField(6, 'pb'); // payload_encoding
    w.writeStringField(7, 'ack'); // payload_type
    w.writeBytesField(8, internalExt); // payload
  });
}

Uint8List _wrapFrame({
  required String payloadType,
  required Uint8List payload,
}) {
  return protoWrite((w) {
    w.writeStringField(6, 'pb'); // payload_encoding
    w.writeStringField(7, payloadType); // payload_type
    w.writeBytesField(8, payload); // payload
  });
}

/// Decompress gzip data if the magic header is present.
Uint8List decompressIfGzipped(
  Uint8List data, {
  int maxOutputBytes = maximumDecompressedPayloadBytes,
}) {
  if (maxOutputBytes < 0) {
    throw ArgumentError.value(
      maxOutputBytes,
      'maxOutputBytes',
      'must be non-negative',
    );
  }
  if (data.length >= 2 && data[0] == 0x1F && data[1] == 0x8B) {
    final output = _BoundedByteSink(maxOutputBytes);
    final decoder = gzip.decoder.startChunkedConversion(output);
    decoder.add(data);
    decoder.close();
    return output.takeBytes();
  }
  if (data.length > maxOutputBytes) {
    throw const FormatException(
      'TikTok payload exceeds the decoded size limit.',
    );
  }
  return data;
}

class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this.maximumBytes);

  final int maximumBytes;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _length = 0;
  bool _closed = false;

  @override
  void add(List<int> data) {
    if (_closed) {
      throw StateError('The decoded payload sink is already closed.');
    }
    if (data.length > maximumBytes - _length) {
      throw const FormatException(
        'TikTok payload exceeds the decoded size limit.',
      );
    }
    _builder.add(data);
    _length += data.length;
  }

  @override
  void close() {
    _closed = true;
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

/// Parse a WebcastPushFrame from raw bytes.
({
  int seqId,
  int logId,
  String payloadEncoding,
  String payloadType,
  Uint8List payload,
})
parsePushFrame(Uint8List raw) {
  final m = protoRead(raw);
  return (
    seqId: m.getVarint(1),
    logId: m.getVarint(2),
    payloadEncoding: m.getString(6),
    payloadType: m.getString(7),
    payload: m.getBytes(8),
  );
}

/// Parse a WebcastResponse from raw bytes.
({
  List<({String method, Uint8List payload, int msgId})> messages,
  Uint8List internalExt,
  bool needsAck,
})
parseResponse(Uint8List raw) {
  final m = protoRead(raw);
  final msgs = m.getRepeatedMessage(1).map((entry) {
    return (
      method: entry.getString(1),
      payload: entry.getBytes(2),
      msgId: entry.getVarint(3),
    );
  }).toList();

  return (messages: msgs, internalExt: m.getBytes(5), needsAck: m.getBool(9));
}
