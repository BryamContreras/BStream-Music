// ignore_for_file: implementation_imports

import 'dart:typed_data';

import 'package:bstream_music/services/live/tiktok_live_dart_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piratetok_live/src/connection/wss.dart';
import 'package:piratetok_live/src/proto/codec.dart';

void main() {
  test(
    'filters 10000 ordinary chats without decoding users and keeps commands',
    () {
      const commandTexts = <int, String>{
        137: '!play Cancion uno',
        5001: '!next',
        10002: 'revoke!',
      };
      final envelope = protoWrite((writer) {
        for (var index = 0; index < 10003; index++) {
          final command = commandTexts[index];
          final payload = command == null
              ? _ordinaryChatPayload(index)
              : _commandChatPayload(index, command);
          writer.writeMessageField(
            1,
            protoWrite((message) {
              message.writeStringField(1, 'WebcastChatMessage');
              message.writeBytesField(2, payload);
              message.writeVarintField(3, index + 1);
            }),
          );
        }
        writer.writeBytesField(5, Uint8List.fromList([7, 8, 9]));
        writer.writeBoolField(9, true);
      });

      final decoded = decodeTikTokResponse(
        envelope,
        'room-load',
        decodedMethods: const {'WebcastChatMessage'},
        chatMessageFilter: isPotentialTikTokLiveCommandText,
      );

      expect(decoded.needsAck, isTrue);
      expect(decoded.internalExt, [7, 8, 9]);
      expect(decoded.events, hasLength(commandTexts.length));
      expect(
        decoded.events.map((event) => event.data?['content']),
        commandTexts.values,
      );
      expect(decoded.events.map((event) => event.roomId).toSet(), {
        'room-load',
      });
      expect(
        decoded.events.map(
          (event) => (event.data?['user'] as Map<String, dynamic>)['uniqueId'],
        ),
        ['viewer137', 'viewer5001', 'viewer10002'],
      );
    },
  );
}

Uint8List _ordinaryChatPayload(int index) {
  return protoWrite((writer) {
    // A rejected ordinary chat must never parse its large User protobuf. The
    // deliberately malformed nested value makes that fast-path observable as
    // a functional assertion instead of a flaky wall-clock benchmark.
    writer.writeBytesField(2, Uint8List.fromList([0x80]));
    writer.writeStringField(3, 'comentario normal $index');
  });
}

Uint8List _commandChatPayload(int index, String command) {
  final user = protoWrite((writer) {
    writer.writeStringField(3, 'Viewer $index');
    writer.writeStringField(38, 'viewer$index');
  });
  return protoWrite((writer) {
    writer.writeMessageField(2, user);
    writer.writeStringField(3, command);
  });
}
