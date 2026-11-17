import 'dart:async';

import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/media_session/desktop_media_session.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a cold media play waits for restoration before resuming', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final play = fixture.session.callbacks!.play();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.controller.calls, isEmpty);

    fixture.completeRestore();
    await play;

    expect(fixture.controller.calls, ['resume:restored-track']);
  });

  test('a cold media next waits for the persisted queue', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final next = fixture.session.callbacks!.next();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.controller.calls, isEmpty);

    fixture.completeRestore();
    await next;

    expect(fixture.controller.calls, ['next:restored-track']);
  });

  test('a cold relative seek uses the restored position', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final seek = fixture.session.callbacks!.seekBy(const Duration(seconds: 15));
    await Future<void>.delayed(Duration.zero);
    expect(fixture.controller.calls, isEmpty);

    fixture.completeRestore();
    await seek;

    expect(fixture.controller.calls, ['seek:57000']);
  });

  test('restoring metadata alone does not request playback', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.completeRestore();
    await fixture.container.read(playerControllerProvider.future);
    await Future<void>.delayed(Duration.zero);

    expect(fixture.controller.calls, isEmpty);
    expect(fixture.session.states.last.snapshot.trackId, 'restored-track');
    expect(fixture.session.states.last.snapshot.wantsToPlay, isFalse);
  });

  test(
    'a command waiting on restoration cannot revive a disposed app',
    () async {
      final fixture = _Fixture();
      final play = fixture.session.callbacks!.play();
      fixture.dispose();
      fixture.completeRestore();

      await play;

      expect(fixture.controller.calls, isEmpty);
    },
  );
}

class _Fixture {
  _Fixture() {
    controller = _RestoringController(restoration.future);
    container = ProviderContainer(
      overrides: [
        playerControllerProvider.overrideWith(() => controller),
        desktopMediaSessionFactoryProvider.overrideWithValue(() => session),
      ],
    );
    container.read(desktopMediaSessionProvider);
  }

  final restoration = Completer<PlayerSnapshot>();
  final session = _Session();
  late final _RestoringController controller;
  late final ProviderContainer container;

  void completeRestore() => restoration.complete(
    const PlayerSnapshot(
      status: PlayerStatus.paused,
      playWhenReady: false,
      trackId: 'restored-track',
      title: 'Restored track',
      artist: 'BStream Music',
      position: Duration(seconds: 42),
      duration: Duration(minutes: 3),
    ),
  );

  void dispose() => container.dispose();
}

class _RestoringController extends PlayerController {
  _RestoringController(this.restoration);

  final Future<PlayerSnapshot> restoration;
  final List<String> calls = [];

  @override
  Future<PlayerSnapshot> build() => restoration;

  @override
  Future<void> resume() async =>
      calls.add('resume:${state.requireValue.trackId}');

  @override
  Future<void> playNext({bool automatic = false}) async =>
      calls.add('next:${state.requireValue.trackId}');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');
}

class _Session implements DesktopMediaSession {
  DesktopMediaSessionCallbacks? callbacks;
  final List<DesktopMediaSessionState> states = [];

  @override
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks) async {
    this.callbacks = callbacks;
  }

  @override
  Future<void> update(DesktopMediaSessionState state) async =>
      states.add(state);

  @override
  Future<void> dispose() async {}
}
