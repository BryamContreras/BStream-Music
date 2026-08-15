import 'dart:async';

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
        text: '!play La pareja del año',
      ),
    );

    expect(event.status, isNull);
    expect(event.command?.action, 'play');
    expect(event.command?.query, 'La pareja del año');
    expect(event.command?.user, 'viewer');
    expect(event.command?.isModerator, isTrue);
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
  });

  test('moderator-only access rejects viewers and accepts moderators', () {
    const viewer = TikTokLiveChatCommand(
      action: 'play',
      user: 'viewer',
      text: '!play Song',
    );
    const moderator = TikTokLiveChatCommand(
      action: 'play',
      user: 'moderator',
      text: '!play Song',
      isModerator: true,
    );

    expect(canUseTikTokCommand(TikTokCommandAccess.everyone, viewer), isTrue);
    expect(
      canUseTikTokCommand(TikTokCommandAccess.moderators, viewer),
      isFalse,
    );
    expect(
      canUseTikTokCommand(TikTokCommandAccess.moderators, moderator),
      isTrue,
    );
  });

  test('controller ignores viewer commands in moderator-only mode', () async {
    SharedPreferences.setMockInitialValues({});
    final service = _FakeTikTokLiveCommandService();
    final container = ProviderContainer(
      overrides: [tiktokLiveCommandServiceProvider.overrideWithValue(service)],
    );
    addTearDown(() async {
      container.dispose();
      await service.close();
    });

    await container.read(tiktokLiveControllerProvider.future);
    await container
        .read(tiktokLiveControllerProvider.notifier)
        .setCommandAccess(TikTokCommandAccess.moderators);
    service.emit(
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
    await Future<void>.delayed(Duration.zero);

    final state = container.read(tiktokLiveControllerProvider).value!;
    expect(state.commandAccess, TikTokCommandAccess.moderators);
    expect(state.liveQueue, isEmpty);
    expect(state.commandsHandled, 0);
    expect(state.message, contains('solo se permiten moderadores'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('tiktokLive.commandAccess'), 'moderators');
  });

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

class _FakeTikTokLiveCommandService extends TikTokLiveCommandService {
  final _controller = StreamController<TikTokLiveEvent>.broadcast();

  @override
  Stream<TikTokLiveEvent> get events => _controller.stream;

  void emit(TikTokLiveEvent event) => _controller.add(event);

  Future<void> close() => _controller.close();
}
