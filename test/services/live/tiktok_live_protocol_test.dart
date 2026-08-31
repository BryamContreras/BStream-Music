// ignore_for_file: implementation_imports

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piratetok_live/src/client.dart';
import 'package:piratetok_live/src/connection/frames.dart';
import 'package:piratetok_live/src/connection/wss.dart';
import 'package:piratetok_live/src/events/router.dart' as event_router;
import 'package:piratetok_live/src/events/types.dart';
import 'package:piratetok_live/src/proto/codec.dart';
import 'package:piratetok_live/src/proto/messages.dart';

void main() {
  test('chat decoder preserves role identity from protobuf fields', () {
    final user = protoWrite((writer) {
      writer.writeStringField(3, 'Moderator');
      writer.writeStringField(38, 'mod.viewer');
      writer.writeBoolField(1090, true);
    });
    final identity = protoWrite((writer) {
      writer.writeBoolField(2, true);
      writer.writeBoolField(5, true);
    });
    final message = protoWrite((writer) {
      writer.writeMessageField(2, user);
      writer.writeStringField(3, '!play Hello');
      writer.writeStringField(14, 'es');
      writer.writeMessageField(18, identity);
    });

    final decoded = decodePayload('WebcastChatMessage', message);

    expect(decoded, isNotNull);
    expect(decoded!.data['content'], '!play Hello');
    expect(
      (decoded.data['user'] as Map<String, dynamic>)['uniqueId'],
      'mod.viewer',
    );
    expect(
      (decoded.data['user'] as Map<String, dynamic>)['isSubscribe'],
      isTrue,
    );
    expect(
      (decoded.data['userIdentity']
          as Map<String, dynamic>)['isSubscriberOfAnchor'],
      isTrue,
    );
    expect(
      (decoded.data['userIdentity']
          as Map<String, dynamic>)['isModeratorOfAnchor'],
      isTrue,
    );
  });

  test('fork exposes a distinct post-handshake lifecycle event', () {
    expect(EventType.websocketConnected, 'websocket_connected');
    expect(EventType.websocketConnected, isNot(EventType.connected));
  });

  test('gzip and response decoding preserve messages and ACK fields', () {
    final envelope = protoWrite((writer) {
      writer.writeMessageField(
        1,
        protoWrite((message) {
          message.writeStringField(1, 'WebcastChatMessage');
          message.writeBytesField(2, Uint8List.fromList([1, 2, 3]));
          message.writeVarintField(3, 42);
        }),
      );
      writer.writeBytesField(5, Uint8List.fromList([9, 8, 7]));
      writer.writeBoolField(9, true);
    });
    final compressed = Uint8List.fromList(gzip.encode(envelope));

    final decoded = parseResponse(decompressIfGzipped(compressed));

    expect(decoded.needsAck, isTrue);
    expect(decoded.internalExt, [9, 8, 7]);
    expect(decoded.messages, hasLength(1));
    expect(decoded.messages.single.method, 'WebcastChatMessage');
    expect(decoded.messages.single.payload, [1, 2, 3]);
    expect(decoded.messages.single.msgId, 42);
  });

  test('gzip decoding rejects output beyond its memory limit', () {
    final expanded = Uint8List(4096);
    final compressed = Uint8List.fromList(gzip.encode(expanded));

    expect(
      () => decompressIfGzipped(compressed, maxOutputBytes: 1024),
      throwsFormatException,
    );
    expect(
      decompressIfGzipped(compressed, maxOutputBytes: expanded.length),
      expanded,
    );
    expect(
      () => decompressIfGzipped(compressed, maxOutputBytes: -1),
      throwsArgumentError,
    );
  });

  test('heartbeat and ACK frames keep room and protocol metadata', () {
    final heartbeat = parsePushFrame(buildHeartbeat('123456789'));
    expect(heartbeat.payloadType, 'hb');
    expect(readTikTokRoomId(heartbeat.payload), 123456789);

    final ack = protoRead(buildAck(77, Uint8List.fromList([4, 5, 6])));
    expect(ack.getVarint(2), 77);
    expect(ack.getString(7), 'ack');
    expect(ack.getBytes(8), [4, 5, 6]);
  });

  test('control action 3 produces one live-ended convenience event', () {
    final payload = protoWrite((writer) {
      writer.writeVarintField(2, 3);
      writer.writeStringField(3, 'LIVE ended');
    });

    final events = event_router.decode(
      'WebcastControlMessage',
      payload,
      'room-1',
    );

    expect(events.map((event) => event.type), [
      EventType.control,
      EventType.liveEnded,
    ]);
    expect(events.last.data?['action'], 3);
    expect(events.last.roomId, 'room-1');
  });

  test('DEVICE_BLOCKED retries end at the configured circuit limit', () {
    final circuit = TikTokDeviceBlockCircuitBreaker(maxRetries: 2);

    expect(circuit.registerFailure(), isTrue);
    expect(circuit.registerFailure(), isTrue);
    expect(circuit.registerFailure(), isFalse);
    expect(circuit.failures, 3);

    circuit.reset();
    expect(circuit.failures, 0);
    expect(circuit.registerFailure(), isTrue);
    expect(
      () => TikTokDeviceBlockCircuitBreaker(maxRetries: -1),
      throwsArgumentError,
    );
  });

  test(
    'response filtering decodes only requested methods and preserves ACK',
    () {
      final envelope = protoWrite((writer) {
        for (final method in const [
          'WebcastChatMessage',
          'WebcastMemberMessage',
          'WebcastControlMessage',
        ]) {
          writer.writeMessageField(
            1,
            protoWrite((message) {
              message.writeStringField(1, method);
              message.writeBytesField(2, Uint8List(0));
            }),
          );
        }
        writer.writeBytesField(5, Uint8List.fromList([7, 8, 9]));
        writer.writeBoolField(9, true);
      });

      final decoded = decodeTikTokResponse(
        envelope,
        'room-filtered',
        decodedMethods: const {'WebcastChatMessage', 'WebcastControlMessage'},
      );

      expect(decoded.events.map((event) => event.type), [
        EventType.chat,
        EventType.control,
      ]);
      expect(
        decoded.events.every((event) => event.roomId == 'room-filtered'),
        isTrue,
      );
      expect(decoded.needsAck, isTrue);
      expect(decoded.internalExt, [7, 8, 9]);
    },
  );

  test(
    'chat message filter skips ordinary profiles and preserves commands and ACK',
    () {
      Uint8List chatPayload(String content, {bool malformedUser = false}) {
        return protoWrite((writer) {
          writer.writeBytesField(
            2,
            malformedUser
                ? Uint8List.fromList([0x80])
                : protoWrite((user) {
                    user.writeStringField(3, 'Viewer');
                    user.writeStringField(38, 'viewer.one');
                  }),
          );
          writer.writeStringField(3, content);
        });
      }

      final envelope = protoWrite((writer) {
        for (final entry in <(String, Uint8List)>[
          (
            'WebcastChatMessage',
            chatPayload('ordinary comment', malformedUser: true),
          ),
          ('WebcastChatMessage', chatPayload('  !play Hello  ')),
          (
            'WebcastControlMessage',
            protoWrite((control) => control.writeVarintField(2, 1)),
          ),
        ]) {
          writer.writeMessageField(
            1,
            protoWrite((message) {
              message.writeStringField(1, entry.$1);
              message.writeBytesField(2, entry.$2);
            }),
          );
        }
        writer.writeBytesField(5, Uint8List.fromList([3, 2, 1]));
        writer.writeBoolField(9, true);
      });
      final inspectedMessages = <String>[];

      final decoded = decodeTikTokResponse(
        envelope,
        'busy-room',
        decodedMethods: const {'WebcastChatMessage', 'WebcastControlMessage'},
        chatMessageFilter: (message) {
          inspectedMessages.add(message);
          return message.trimLeft().startsWith('!');
        },
      );

      expect(inspectedMessages, ['ordinary comment', '  !play Hello  ']);
      expect(decoded.events.map((event) => event.type), [
        EventType.chat,
        EventType.control,
      ]);
      expect(decoded.events.first.data?['content'], '  !play Hello  ');
      expect(
        (decoded.events.first.data?['user']
            as Map<String, dynamic>)['uniqueId'],
        'viewer.one',
      );
      expect(decoded.needsAck, isTrue);
      expect(decoded.internalExt, [3, 2, 1]);
    },
  );
}

int readTikTokRoomId(Uint8List payload) => protoRead(payload).getVarint(1);
