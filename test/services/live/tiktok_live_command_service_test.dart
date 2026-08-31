import 'dart:async';
import 'dart:convert';

import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('normalizes TikTok creator input from handles and live links', () {
    expect(normalizeCreatorInput('@cossette'), 'cossette');
    expect(
      normalizeCreatorInput('https://www.tiktok.com/@cossette/live'),
      'cossette',
    );
    expect(
      normalizeCreatorInput('https://www.tiktok.com/@cossette?lang=es'),
      'cossette',
    );
    expect(normalizeCreatorInput(' @co.ssette_123 '), 'co.ssette_123');
  });

  test('parses command events', () {
    const event = TikTokLiveEvent(
      type: 'command',
      command: TikTokLiveChatCommand(
        action: 'play',
        query: 'La pareja del año',
        user: 'viewer',
        isModerator: true,
        isSubscriber: true,
        text: '!play La pareja del año',
      ),
    );

    expect(event.status, isNull);
    expect(event.command?.action, 'play');
    expect(event.command?.query, 'La pareja del año');
    expect(event.command?.user, 'viewer');
    expect(event.command?.isModerator, isTrue);
    expect(event.command?.isSubscriber, isTrue);
  });

  test('defaults command requester to a regular viewer', () {
    const event = TikTokLiveEvent(
      type: 'command',
      command: TikTokLiveChatCommand(
        action: 'play',
        query: 'Song',
        user: 'viewer',
        text: '!play Song',
      ),
    );

    expect(event.command?.isModerator, isFalse);
    expect(event.command?.isSubscriber, isFalse);
  });

  test('command permissions combine public and privileged audiences', () {
    const permissions = TikTokCommandPermissions(
      everyone: {TikTokLiveCommand.play},
      moderators: {TikTokLiveCommand.skip, TikTokLiveCommand.stop},
      subscribers: {TikTokLiveCommand.revoke},
    );

    for (final action in const ['play', 'skip', 'revoke', 'stop']) {
      expect(
        canUseTikTokCommand(permissions, _command(action)),
        action == 'play',
        reason: 'viewer: $action',
      );
      expect(
        canUseTikTokCommand(permissions, _command(action, isModerator: true)),
        action == 'play' || action == 'skip' || action == 'stop',
        reason: 'moderator: $action',
      );
      expect(
        canUseTikTokCommand(permissions, _command(action, isSubscriber: true)),
        action == 'play' || action == 'revoke',
        reason: 'subscriber: $action',
      );
      expect(
        canUseTikTokCommand(
          permissions,
          _command(action, isModerator: true, isSubscriber: true),
        ),
        isTrue,
        reason: 'moderator and subscriber: $action',
      );
    }

    expect(canUseTikTokCommand(permissions, _command('unknown')), isFalse);
  });

  test(
    'controller defaults every command to everyone and stores v3 JSON',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = _LiveControllerFixture();
      addTearDown(fixture.dispose);

      final state = await fixture.container.read(
        tiktokLiveControllerProvider.future,
      );

      expect(state.commandPermissions.everyone, allTikTokLiveCommands);
      expect(state.commandPermissions.moderators, isEmpty);
      expect(state.commandPermissions.subscribers, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('tiktokLive.commandPermissions.v3')!), {
        'version': 3,
        'everyone': ['play', 'skip', 'revoke', 'stop'],
        'moderators': <Object>[],
        'subscribers': <Object>[],
      });
    },
  );

  test(
    'legacy moderator access migrates every command to moderators',
    () async {
      SharedPreferences.setMockInitialValues({
        'tiktokLive.commandAccess': 'moderators',
      });
      final fixture = _LiveControllerFixture();
      addTearDown(fixture.dispose);

      final state = await fixture.container.read(
        tiktokLiveControllerProvider.future,
      );

      expect(state.commandPermissions.everyone, isEmpty);
      expect(state.commandPermissions.moderators, allTikTokLiveCommands);
      expect(state.commandPermissions.subscribers, isEmpty);
      expect(
        canUseTikTokCommand(state.commandPermissions, _command('play')),
        isFalse,
      );
      expect(
        canUseTikTokCommand(
          state.commandPermissions,
          _command('play', isModerator: true),
        ),
        isTrue,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('tiktokLive.commandPermissions.v3')!), {
        'version': 3,
        'everyone': <Object>[],
        'moderators': ['play', 'skip', 'revoke', 'stop'],
        'subscribers': <Object>[],
      });
    },
  );

  test('v2 permissions migrate revoke to stop for each audience', () async {
    SharedPreferences.setMockInitialValues({
      'tiktokLive.commandPermissions.v2': jsonEncode({
        'version': 2,
        'everyone': ['play', 'revoke'],
        'moderators': ['skip'],
        'subscribers': ['revoke'],
      }),
    });
    final fixture = _LiveControllerFixture();
    addTearDown(fixture.dispose);

    final state = await fixture.container.read(
      tiktokLiveControllerProvider.future,
    );

    expect(state.commandPermissions.everyone, {
      TikTokLiveCommand.play,
      TikTokLiveCommand.revoke,
      TikTokLiveCommand.stop,
    });
    expect(state.commandPermissions.moderators, {TikTokLiveCommand.skip});
    expect(state.commandPermissions.subscribers, {
      TikTokLiveCommand.revoke,
      TikTokLiveCommand.stop,
    });

    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('tiktokLive.commandPermissions.v3')!), {
      'version': 3,
      'everyone': ['play', 'revoke', 'stop'],
      'moderators': ['skip'],
      'subscribers': ['revoke', 'stop'],
    });
  });

  test(
    'v3 restores revoke enabled and stop disabled without coupling',
    () async {
      final stored = jsonEncode({
        'version': 3,
        'everyone': ['revoke'],
        'moderators': ['stop'],
        'subscribers': <Object>[],
      });
      SharedPreferences.setMockInitialValues({
        'tiktokLive.commandPermissions.v3': stored,
      });
      final fixture = _LiveControllerFixture();
      addTearDown(fixture.dispose);

      final state = await fixture.container.read(
        tiktokLiveControllerProvider.future,
      );

      expect(state.commandPermissions.everyone, {TikTokLiveCommand.revoke});
      expect(state.commandPermissions.moderators, {TikTokLiveCommand.stop});
      expect(state.commandPermissions.subscribers, isEmpty);
      expect(
        canUseTikTokCommand(state.commandPermissions, _command('revoke')),
        isTrue,
      );
      expect(
        canUseTikTokCommand(state.commandPermissions, _command('stop')),
        isFalse,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('tiktokLive.commandPermissions.v3'), stored);
    },
  );

  test(
    'granular command permissions persist and restore independently',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = _LiveControllerFixture();
      try {
        await first.container.read(tiktokLiveControllerProvider.future);
        final controller = first.container.read(
          tiktokLiveControllerProvider.notifier,
        );
        await controller.setCommandPermission(
          TikTokCommandAudience.everyone,
          TikTokLiveCommand.skip,
          false,
        );
        await controller.setCommandPermission(
          TikTokCommandAudience.moderators,
          TikTokLiveCommand.skip,
          true,
        );
        await controller.setCommandPermission(
          TikTokCommandAudience.subscribers,
          TikTokLiveCommand.revoke,
          true,
        );

        final permissions = first.container
            .read(tiktokLiveControllerProvider)
            .requireValue
            .commandPermissions;
        expect(permissions.everyone, {
          TikTokLiveCommand.play,
          TikTokLiveCommand.revoke,
          TikTokLiveCommand.stop,
        });
        expect(permissions.moderators, {TikTokLiveCommand.skip});
        expect(permissions.subscribers, {TikTokLiveCommand.revoke});

        final prefs = await SharedPreferences.getInstance();
        expect(
          jsonDecode(prefs.getString('tiktokLive.commandPermissions.v3')!),
          {
            'version': 3,
            'everyone': ['play', 'revoke', 'stop'],
            'moderators': ['skip'],
            'subscribers': ['revoke'],
          },
        );
      } finally {
        await first.dispose();
      }

      final restored = _LiveControllerFixture();
      addTearDown(restored.dispose);
      final restoredState = await restored.container.read(
        tiktokLiveControllerProvider.future,
      );
      expect(restoredState.commandPermissions.everyone, {
        TikTokLiveCommand.play,
        TikTokLiveCommand.revoke,
        TikTokLiveCommand.stop,
      });
      expect(restoredState.commandPermissions.moderators, {
        TikTokLiveCommand.skip,
      });
      expect(restoredState.commandPermissions.subscribers, {
        TikTokLiveCommand.revoke,
      });
    },
  );

  test(
    'controller rejects a command missing from the requester audiences',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = _LiveControllerFixture();
      addTearDown(fixture.dispose);

      await fixture.container.read(tiktokLiveControllerProvider.future);
      await fixture.container
          .read(tiktokLiveControllerProvider.notifier)
          .setCommandPermission(
            TikTokCommandAudience.everyone,
            TikTokLiveCommand.play,
            false,
          );
      await fixture.container
          .read(tiktokLiveControllerProvider.notifier)
          .setCommandPermission(
            TikTokCommandAudience.moderators,
            TikTokLiveCommand.play,
            true,
          );
      fixture.service.emit(
        const TikTokLiveEvent(
          type: 'command',
          command: TikTokLiveChatCommand(
            action: 'play',
            query: 'Blocked song',
            user: 'viewer',
            isModerator: false,
            text: '!play Blocked song',
          ),
        ),
      );
      await _flushEvents();

      final state = fixture.container
          .read(tiktokLiveControllerProvider)
          .requireValue;
      expect(state.liveQueue, isEmpty);
      expect(state.commandsHandled, 0);
      expect(state.lastCommand?.user, 'viewer');
      expect(state.message, contains('Comando no permitido'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('tiktokLive.commandAccess'), isNull);
    },
  );

  test('maps status events', () {
    const event = TikTokLiveEvent(
      type: 'status',
      status: TikTokLiveStatus.connected,
      user: 'cossette',
      roomId: '123',
      message: 'Conectado',
    );

    expect(event.status, TikTokLiveStatus.connected);
    expect(event.user, 'cossette');
    expect(event.roomId, '123');
  });
}

TikTokLiveChatCommand _command(
  String action, {
  bool isModerator = false,
  bool isSubscriber = false,
}) {
  return TikTokLiveChatCommand(
    action: action,
    user: 'viewer',
    text: '!$action',
    isModerator: isModerator,
    isSubscriber: isSubscriber,
  );
}

Future<void> _flushEvents() async {
  for (var index = 0; index < 4; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _LiveControllerFixture {
  _LiveControllerFixture() : service = _FakeTikTokLiveCommandService() {
    container = ProviderContainer(
      overrides: [tiktokLiveCommandServiceProvider.overrideWithValue(service)],
    );
  }

  final _FakeTikTokLiveCommandService service;
  late final ProviderContainer container;

  Future<void> dispose() async {
    container.dispose();
    await service.close();
  }
}

class _FakeTikTokLiveCommandService extends TikTokLiveCommandService {
  final _controller = StreamController<TikTokLiveEvent>.broadcast();

  @override
  Stream<TikTokLiveEvent> get events => _controller.stream;

  void emit(TikTokLiveEvent event) => _controller.add(event);

  Future<void> close() => _controller.close();
}
