import 'dart:async';

import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/live/tiktok_live_dart_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseTikTokLiveCommand', () {
    test('cheaply identifies only possible command chat lines', () {
      for (final text in const [
        '!play Hello',
        '  !SKIP  ',
        '!unknown still worth validating',
        'revoke!',
        '  ReVoKe! ',
      ]) {
        expect(isPotentialTikTokLiveCommandText(text), isTrue, reason: text);
      }
      for (final text in const [
        '',
        'ordinary comment',
        'please !play this',
        'revoke',
      ]) {
        expect(isPotentialTikTokLiveCommandText(text), isFalse, reason: text);
      }
    });

    test('parses play while preserving query and requester metadata', () {
      final command = parseTikTokLiveCommand(
        '  !PlAy   La pareja del año  ',
        user: 'viewer.one',
        isModerator: true,
      );

      expect(command, isNotNull);
      expect(command!.action, 'play');
      expect(command.query, 'La pareja del año');
      expect(command.user, 'viewer.one');
      expect(command.text, '!PlAy   La pareja del año');
      expect(command.isModerator, isTrue);
    });

    test('maps aliases to the existing skip and revoke actions', () {
      for (final text in const ['!skip', '!next']) {
        expect(
          parseTikTokLiveCommand(text, user: 'viewer')?.action,
          'skip',
          reason: text,
        );
      }
      for (final text in const ['!revoke', '!stop', 'revoke!']) {
        expect(
          parseTikTokLiveCommand(text, user: 'viewer')?.action,
          'revoke',
          reason: text,
        );
      }
    });

    test('ignores ordinary chat, unknown commands and play without query', () {
      for (final text in const [
        'hello chat',
        '!',
        '!unknown song',
        '!play',
        '!play    ',
        '',
      ]) {
        expect(
          parseTikTokLiveCommand(text, user: 'viewer'),
          isNull,
          reason: text,
        );
      }
    });
  });

  group('isTikTokLiveModerator', () {
    test('supports known camelCase and snake_case user fields', () {
      for (final user in <Map<String, dynamic>>[
        {'isModeratorOfAnchor': true},
        {'is_moderator_of_anchor': true},
        {'isModerator': true},
        {'is_moderator': true},
      ]) {
        expect(isTikTokLiveModerator(user), isTrue, reason: '$user');
      }
    });

    test('supports identity metadata nested in the event payload', () {
      expect(
        isTikTokLiveModerator(
          const {},
          eventData: const {
            'userIdentity': {'isModeratorOfAnchor': true},
          },
        ),
        isTrue,
      );
      expect(
        isTikTokLiveModerator(const {
          'userIdentity': {'is_moderator': true},
        }),
        isTrue,
      );
    });

    test('supports the current ADMIN badge representation', () {
      expect(
        isTikTokLiveModerator(const {
          'badgeList': [
            {'badgeSceneType': 1},
          ],
        }),
        isTrue,
      );
      expect(
        isTikTokLiveModerator(const {
          'badges': [
            {'badge_scene': 'ADMIN'},
          ],
        }),
        isTrue,
      );
    });

    test('does not grant moderator access for absent or false flags', () {
      expect(isTikTokLiveModerator(null), isFalse);
      expect(isTikTokLiveModerator(const {}), isFalse);
      expect(
        isTikTokLiveModerator(const {'isModeratorOfAnchor': false}),
        isFalse,
      );
    });
  });

  group('TikTokLiveDartAdapter', () {
    late List<_FakeTikTokLiveDartClient> clients;
    late TikTokLiveDartAdapter adapter;
    late List<TikTokLiveEvent> events;
    late StreamSubscription<TikTokLiveEvent> subscription;

    setUp(() {
      clients = [];
      adapter = TikTokLiveDartAdapter(
        clientFactory: (user) {
          final client = _FakeTikTokLiveDartClient(user: user);
          clients.add(client);
          return client;
        },
        restartDelay: const Duration(milliseconds: 20),
        maxSessionRestarts: 2,
      );
      events = [];
      subscription = adapter.events.listen(events.add);
    });

    tearDown(() async {
      await subscription.cancel();
      await adapter.dispose();
    });

    test(
      'does not claim connected until a real traffic event arrives',
      () async {
        await adapter.connect('@creator');
        final client = clients.single;

        expect(client.user, 'creator');
        expect(adapter.isRunning, isTrue);
        expect(
          events.where((event) => event.status == TikTokLiveStatus.connected),
          isEmpty,
        );

        client.emit('connected', roomId: 'room-42');
        await _flushEvents();
        expect(
          events.where((event) => event.status == TikTokLiveStatus.connected),
          isEmpty,
        );

        client.emit('member', roomId: 'room-42');
        await _flushEvents();
        final connected = events.lastWhere(
          (event) => event.status == TikTokLiveStatus.connected,
        );
        expect(connected.user, 'creator');
        expect(connected.roomId, 'room-42');
      },
    );

    test(
      'websocket-connected confirms the room discovered by connected',
      () async {
        await adapter.connect('creator');
        final client = clients.single;

        client.emit('connected', roomId: 'discovered-room');
        await _flushEvents();
        expect(
          events.where((event) => event.status == TikTokLiveStatus.connected),
          isEmpty,
        );

        client.emit('websocket_connected');
        await _flushEvents();

        final connected = events.lastWhere(
          (event) => event.status == TikTokLiveStatus.connected,
        );
        expect(connected.user, 'creator');
        expect(connected.roomId, 'discovered-room');
      },
    );

    test('emits parsed chat commands with moderator metadata', () async {
      await adapter.connect('creator');
      clients.single.emit(
        'chat',
        data: const {
          'comment': '!play Hello',
          'user': {'uniqueId': 'moderator.viewer', 'isModeratorOfAnchor': true},
        },
        roomId: 'room-1',
      );
      await _flushEvents();

      final event = events.lastWhere((event) => event.command != null);
      expect(event.command?.action, 'play');
      expect(event.command?.query, 'Hello');
      expect(event.command?.user, 'moderator.viewer');
      expect(event.command?.isModerator, isTrue);
      expect(event.roomId, 'room-1');
    });

    test(
      'maps reconnecting to connecting without accepting stale traffic',
      () async {
        await adapter.connect('first_creator');
        final oldClient = clients.single;
        oldClient.emit('member', roomId: 'old-room');
        await _flushEvents();

        await adapter.connect('second_creator');
        final currentClient = clients.last;
        expect(oldClient.disconnectCalls, greaterThanOrEqualTo(1));

        oldClient.emit(
          'chat',
          data: const {
            'comment': '!play Stale Song',
            'user': {'uniqueId': 'stale.viewer'},
          },
        );
        currentClient.emit('reconnecting');
        await _flushEvents();

        expect(
          events.where((event) => event.command?.query == 'Stale Song'),
          isEmpty,
        );
        expect(events.last.status, TikTokLiveStatus.connecting);
      },
    );

    test(
      'ignores completion and events from a superseded generation',
      () async {
        await adapter.connect('first_creator');
        await _flushEvents();
        final firstClient = clients.single;
        firstClient.completeConnectionOnDisconnect = false;

        final secondConnect = adapter.connect('second_creator');
        await _flushEvents();
        firstClient.emit(
          'chat',
          data: const {
            'comment': '!play Stale While Stopping',
            'user': {'uniqueId': 'stale.viewer'},
          },
          roomId: 'old-room',
        );
        firstClient.completeConnect('old-room');
        await secondConnect;
        final secondClient = clients.last;

        firstClient.emit('member', roomId: 'old-room');
        secondClient.emit('member', roomId: 'new-room');
        await _flushEvents();

        expect(
          events.where(
            (event) => event.command?.query == 'Stale While Stopping',
          ),
          isEmpty,
        );
        final connectedEvents = events.where(
          (event) => event.status == TikTokLiveStatus.connected,
        );
        expect(connectedEvents, hasLength(1));
        expect(connectedEvents.single.user, 'second_creator');
        expect(connectedEvents.single.roomId, 'new-room');
      },
    );

    test('manual disconnect cancels a scheduled automatic restart', () async {
      await adapter.connect('creator');
      clients.single.completeConnect('closed-room');
      await _flushEvents();

      await adapter.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(adapter.isRunning, isFalse);
      expect(clients, hasLength(1));
    });

    test('disconnect ignores late traffic from the cancelled client', () async {
      await adapter.connect('creator');
      final cancelledClient = clients.single;

      await adapter.disconnect();
      cancelledClient.emit(
        'chat',
        data: const {
          'comment': '!play Too Late',
          'user': {'uniqueId': 'late.viewer'},
        },
      );
      cancelledClient.emit('member', roomId: 'late-room');
      await _flushEvents();

      expect(
        events.where((event) => event.command?.query == 'Too Late'),
        isEmpty,
      );
      expect(events.where((event) => event.roomId == 'late-room'), isEmpty);
      expect(events.last.status, TikTokLiveStatus.disconnected);
    });

    test('live-ended is terminal and does not schedule a restart', () async {
      await adapter.connect('creator');
      clients.single.emit(
        'live_ended',
        data: const {'message': 'Creator ended the LIVE'},
        roomId: 'ended-room',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(adapter.isRunning, isFalse);
      expect(clients, hasLength(1));
      final terminal = events.lastWhere(
        (event) => event.status == TikTokLiveStatus.liveEnded,
      );
      expect(terminal.roomId, 'ended-room');
      expect(terminal.message, 'Creator ended the LIVE');
    });

    test(
      'restarts a dropped session and accepts only the new client',
      () async {
        await adapter.connect('creator');
        final firstClient = clients.single;
        firstClient.completeConnect('closed-room');
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(clients, hasLength(2));
        final restartedClient = clients.last;
        firstClient.emit(
          'chat',
          data: const {
            'comment': '!skip',
            'user': {'uniqueId': 'stale'},
          },
        );
        restartedClient.emit(
          'chat',
          data: const {
            'comment': '!next',
            'user': {'uniqueId': 'current'},
          },
          roomId: 'new-room',
        );
        await _flushEvents();

        final commands = events
            .map((event) => event.command)
            .whereType<TikTokLiveChatCommand>()
            .toList();
        expect(commands, hasLength(1));
        expect(commands.single.action, 'skip');
        expect(commands.single.user, 'current');
      },
    );

    test('concurrent connects leave only the latest client active', () async {
      await Future.wait([
        adapter.connect('first_creator'),
        adapter.connect('second_creator'),
      ]);
      await _flushEvents();

      expect(clients, isNotEmpty);
      expect(clients.last.user, 'second_creator');
      final activeClients = clients
          .where((client) => client.disconnectCalls == 0)
          .toList();
      expect(activeClients, hasLength(1));
      expect(activeClients.single.user, 'second_creator');
      for (final staleClient in clients.take(clients.length - 1)) {
        expect(staleClient.disconnectCalls, greaterThanOrEqualTo(1));
      }
    });

    test(
      'disconnect wins while a connect is waiting for the old worker',
      () async {
        await adapter.connect('old_creator');
        final oldClient = clients.single;
        oldClient.completeConnectionOnDisconnect = false;

        final replacement = adapter.connect('new_creator');
        await _flushEvents();
        expect(oldClient.disconnectCalls, greaterThanOrEqualTo(1));

        await adapter.disconnect();
        oldClient.completeConnect('old-room');
        await replacement;
        await _flushEvents();

        expect(clients, hasLength(1));
        expect(adapter.isRunning, isFalse);
        expect(events.where((event) => event.user == 'new_creator'), isEmpty);
      },
    );

    test(
      'dispose wins while a connect is waiting for the old worker',
      () async {
        await adapter.connect('old_creator');
        final oldClient = clients.single;
        oldClient.completeConnectionOnDisconnect = false;

        final replacement = adapter.connect('new_creator');
        await _flushEvents();
        final disposing = adapter.dispose();
        await disposing;

        oldClient.completeConnect('old-room');
        await replacement;
        await _flushEvents();

        expect(clients, hasLength(1));
        expect(adapter.isRunning, isFalse);
        expect(events.where((event) => event.user == 'new_creator'), isEmpty);
      },
    );
  });
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeTikTokLiveDartClient implements TikTokLiveDartClient {
  _FakeTikTokLiveDartClient({required this.user});

  final String user;
  final Map<String, List<void Function(TikTokLiveDartRawEvent)>> _handlers = {};
  final Completer<String> _connectCompleter = Completer<String>();
  bool completeConnectionOnDisconnect = true;
  int disconnectCalls = 0;

  @override
  void on(
    String eventType,
    void Function(TikTokLiveDartRawEvent event) handler,
  ) {
    _handlers.putIfAbsent(eventType, () => []).add(handler);
  }

  @override
  Future<String> connect() => _connectCompleter.future;

  void completeConnect(String roomId) {
    if (!_connectCompleter.isCompleted) {
      _connectCompleter.complete(roomId);
    }
  }

  @override
  void disconnect() {
    disconnectCalls += 1;
    if (completeConnectionOnDisconnect && !_connectCompleter.isCompleted) {
      _connectCompleter.complete('room-$user');
    }
  }

  void emit(String type, {Map<String, dynamic>? data, String roomId = ''}) {
    final event = TikTokLiveDartRawEvent(
      type: type,
      data: data,
      roomId: roomId,
    );
    for (final handler in List.of(_handlers[type] ?? const [])) {
      handler(event);
    }
  }
}
