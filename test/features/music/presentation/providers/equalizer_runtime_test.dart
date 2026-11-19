import 'dart:async';

import 'package:bstream_music/features/music/presentation/providers/equalizer_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const initial = EqualizerSettings(
    enabled: true,
    gainsDb: [3, 3, 2, 1, 0, 0, 1, 1, 2, 3],
  );
  const latest = EqualizerSettings(
    enabled: true,
    gainsDb: [6, 6, 4, 2, 1, 0, -1, -1, 0, 0],
  );
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 110));

  ProviderContainer container(PlayerService player) {
    final result = ProviderContainer(
      overrides: [
        playerServiceProvider.overrideWithValue(player),
        settingsControllerProvider.overrideWith(() => _Settings(initial)),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  test(
    'saved tuning applies without opening the page and slider writes coalesce',
    () async {
      final player = _Player();
      final scope = container(player);
      scope.read(equalizerRuntimeProvider);
      await scope.read(settingsControllerProvider.future);
      await settle();
      expect(player.curves, [initial]);
      final settings =
          scope.read(settingsControllerProvider.notifier) as _Settings;
      for (var i = 0; i < 20; i++) {
        settings.setCurve(initial.withBand(0, i / 2));
      }
      settings.setCurve(latest);
      await settle();
      expect(player.curves, [initial, latest]);
      settings.setCurve(latest);
      await settle();
      expect(player.curves, hasLength(2));
    },
  );

  test('slow native writes serialize and the latest setting wins', () async {
    final player = _Player()..blocked = Completer<void>();
    final scope = container(player);
    scope.read(equalizerRuntimeProvider);
    await scope.read(settingsControllerProvider.future);
    await settle();
    expect(scope.read(equalizerRuntimeProvider).applying, isTrue);
    final settings =
        scope.read(settingsControllerProvider.notifier) as _Settings;
    settings.setCurve(initial.withBand(0, -6));
    settings.setCurve(latest);
    await settle();
    expect(player.curves, [initial]);
    player.blocked!.complete();
    await settle();
    expect(player.curves, [initial, latest]);
    expect(scope.read(equalizerRuntimeProvider).applying, isFalse);
  });

  test('a continuous gesture updates sound before the gesture ends', () async {
    final player = _Player();
    final scope = container(player);
    scope.read(equalizerRuntimeProvider);
    await scope.read(settingsControllerProvider.future);
    await settle();
    final settings =
        scope.read(settingsControllerProvider.notifier) as _Settings;
    for (var i = 0; i < 20; i++) {
      settings.setCurve(initial.withBand(0, i / 2));
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(player.curves.length, greaterThan(2));
    await settle();
    expect(player.curves.last, initial.withBand(0, 9.5));
  });

  test(
    'optional effect failures surface without becoming playback errors',
    () async {
      final player = _Player()..error = StateError('native EQ unavailable');
      final scope = container(player);
      scope.read(equalizerRuntimeProvider);
      await scope.read(settingsControllerProvider.future);
      await settle();
      expect(scope.read(equalizerRuntimeProvider).error, isStateError);
      player.error = null;
      (scope.read(settingsControllerProvider.notifier) as _Settings).setCurve(
        latest,
      );
      await settle();
      expect(scope.read(equalizerRuntimeProvider).error, isNull);
      expect(player.curves.last, latest);
    },
  );

  test(
    'replacing an engine cannot publish a stale write into the new binding',
    () async {
      final original = _Player()..blocked = Completer<void>();
      final scope = container(original);
      scope.read(equalizerRuntimeProvider);
      await scope.read(settingsControllerProvider.future);
      await settle();
      final replacement = _Player();
      scope.updateOverrides([
        playerServiceProvider.overrideWithValue(replacement),
        settingsControllerProvider.overrideWith(() => _Settings(initial)),
      ]);
      scope.read(equalizerRuntimeProvider);
      await settle();
      original.blocked!.complete();
      await settle();
      expect(replacement.curves, [initial]);
      expect(scope.read(equalizerRuntimeProvider).applying, isFalse);
    },
  );

  test('unsupported engines receive no effect commands', () async {
    final player = _Player(supported: false);
    final scope = container(player);
    expect(scope.read(equalizerRuntimeProvider).supported, isFalse);
    await scope.read(settingsControllerProvider.future);
    await settle();
    expect(player.curves, isEmpty);
  });

  test('hardware support discovered after load updates availability', () async {
    final snapshots = StreamController<PlayerSnapshot>.broadcast();
    addTearDown(snapshots.close);
    final player = _Player(snapshots: snapshots.stream);
    final scope = container(player);
    expect(scope.read(equalizerAvailableProvider), isTrue);
    player.supported = false;
    snapshots.add(const PlayerSnapshot(status: PlayerStatus.playing));
    await settle();
    expect(scope.read(equalizerRuntimeProvider).supported, isFalse);
    expect(scope.read(equalizerAvailableProvider), isFalse);
  });

  test(
    'returning to an earlier preset restores it after a rejected update',
    () async {
      final player = _Player();
      final scope = container(player);
      scope.read(equalizerRuntimeProvider);
      await scope.read(settingsControllerProvider.future);
      await settle();
      player.error = StateError('rejected curve');
      final settings =
          scope.read(settingsControllerProvider.notifier) as _Settings;
      settings.setCurve(latest);
      await settle();
      expect(scope.read(equalizerRuntimeProvider).error, isNotNull);
      player.error = null;
      settings.setCurve(initial);
      await settle();
      expect(player.curves, [initial, latest, initial]);
      expect(scope.read(equalizerRuntimeProvider).error, isNull);
    },
  );
}

class _Settings extends SettingsController {
  _Settings(this.initial);
  final EqualizerSettings initial;
  @override
  Future<SettingsState> build() async => SettingsState(
    downloadDirectory: '/unused',
    language: AppLanguage.english,
    equalizer: initial,
  );
  void setCurve(EqualizerSettings settings) {
    state = AsyncData(state.requireValue.copyWith(equalizer: settings));
  }
}

class _Player extends Fake implements PlayerService, EqualizerCapablePlayer {
  _Player({this.supported = true, this.snapshots = const Stream.empty()});
  bool supported;
  final Stream<PlayerSnapshot> snapshots;
  final curves = <EqualizerSettings>[];
  @override
  Stream<PlayerSnapshot> get snapshotStream => snapshots;
  Completer<void>? blocked;
  Object? error;
  @override
  bool get supportsEqualizer => supported;
  @override
  Future<void> configureEqualizer(EqualizerSettings settings) async {
    curves.add(settings);
    await blocked?.future;
    if (error != null) throw error!;
  }
}
