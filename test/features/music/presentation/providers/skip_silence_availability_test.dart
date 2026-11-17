import 'dart:async';

import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'asset support changes update settings without position tick rebuilds',
    () async {
      final player = _Player();
      final scope = ProviderContainer(
        overrides: [playerServiceProvider.overrideWithValue(player)],
      );
      addTearDown(player.events.close);
      addTearDown(scope.dispose);
      final values = <bool>[];
      final subscription = scope.listen(
        skipSilenceAvailableProvider,
        (_, next) => values.add(next),
      );
      addTearDown(subscription.close);
      await scope.read(skipSilenceRouteAvailabilityProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(scope.read(skipSilenceAvailableProvider), isTrue);
      final initialNotifications = values.length;
      for (var i = 0; i < 50; i++) {
        player.emit();
      }
      await Future<void>.delayed(Duration.zero);
      expect(values.length, initialNotifications);
      player.supported = false;
      player.emit();
      await Future<void>.delayed(Duration.zero);
      expect(scope.read(skipSilenceAvailableProvider), isFalse);
      player.supported = true;
      player.emit();
      await Future<void>.delayed(Duration.zero);
      expect(scope.read(skipSilenceAvailableProvider), isTrue);
      expect(values.skip(initialNotifications), [false, true]);
    },
  );

  test('a backend without silence processing reports unavailable', () async {
    final scope = ProviderContainer(
      overrides: [
        playerServiceProvider.overrideWithValue(_UnsupportedPlayer()),
      ],
    );
    addTearDown(scope.dispose);
    final subscription = scope.listen(skipSilenceAvailableProvider, (_, _) {});
    addTearDown(subscription.close);
    expect(scope.read(skipSilenceAvailableProvider), isFalse);
    expect(
      await scope.read(skipSilenceRouteAvailabilityProvider.future),
      isFalse,
    );
  });

  test(
    'a known unavailable asset stays unavailable during initial loading',
    () async {
      final player = _Player()..supported = false;
      final scope = ProviderContainer(
        overrides: [playerServiceProvider.overrideWithValue(player)],
      );
      addTearDown(player.events.close);
      addTearDown(scope.dispose);
      final values = <bool>[];
      final subscription = scope.listen(
        skipSilenceAvailableProvider,
        (_, next) => values.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      expect(scope.read(skipSilenceAvailableProvider), isFalse);
      expect(
        await scope.read(skipSilenceRouteAvailabilityProvider.future),
        isFalse,
      );
      expect(values, everyElement(isFalse));
    },
  );
}

class _Player extends Fake implements PlayerService, SkipSilenceCapablePlayer {
  bool supported = true;
  final events = StreamController<PlayerSnapshot>.broadcast(sync: true);
  @override
  bool get supportsSkipSilence => supported;
  @override
  Stream<PlayerSnapshot> get snapshotStream => events.stream;
  void emit() => events.add(const PlayerSnapshot(status: PlayerStatus.playing));
}

class _UnsupportedPlayer extends Fake implements PlayerService {}
