import 'dart:async';
import 'dart:io';

import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/live_overlay_controller.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/live/local_overlay_hosts.dart';
import 'package:bstream_music/services/live/local_overlay_server.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts at the active LIVE song and publishes at most five items', () {
    final queue = <LiveQueueItem>[
      _item(0),
      _item(1, status: LiveQueueItemStatus.failed),
      _item(2),
      _item(3, status: LiveQueueItemStatus.resolving, resolved: false),
      _item(4, status: LiveQueueItemStatus.downloading, resolved: false),
      _item(5),
      _item(6),
      _item(7),
    ];

    final selection = selectLiveOverlayQueue(
      queue,
      playback: const PlayerSnapshot(
        status: PlayerStatus.playing,
        trackId: 'track-2',
        isRemote: true,
      ),
      isLiveQueueActive: true,
    );

    expect(selection.currentItemId, 'request-2');
    expect(selection.entries.map((item) => item.id), [
      'request-2',
      'request-3',
      'request-4',
      'request-5',
      'request-6',
    ]);
    expect(selection.entries.first.status, 'playing');
    expect(selection.entries[1].status, 'resolving');
    expect(selection.entries[1].artist, isEmpty);
    expect(selection.entries.first.artworkSource, 'https://img.test/2.jpg');
    expect(selection.entries.first.toJson(), isNot(contains('requestedBy')));
  });

  test('keeps the last cursor and never returns played history', () {
    final selection = selectLiveOverlayQueue(
      List<LiveQueueItem>.generate(8, _item),
      playback: const PlayerSnapshot(
        status: PlayerStatus.loading,
        trackId: 'temporarily-unavailable',
        isRemote: true,
      ),
      isLiveQueueActive: true,
      previousCurrentItemId: 'request-4',
    );

    expect(selection.currentItemId, 'request-4');
    expect(selection.entries.map((item) => item.id), [
      'request-4',
      'request-5',
      'request-6',
      'request-7',
    ]);
  });

  test('omits failed items when playback has not started', () {
    final selection = selectLiveOverlayQueue([
      _item(0, status: LiveQueueItemStatus.failed),
      _item(1, status: LiveQueueItemStatus.resolving, resolved: false),
      _item(2),
    ]);

    expect(selection.currentItemId, isNull);
    expect(selection.entries.map((item) => item.id), [
      'request-1',
      'request-2',
    ]);
  });

  test(
    'starts local HTTP, publishes localized queue/progress, and stops',
    () async {
      final live = _FakeLiveController([_item(0), _item(1), _item(2)]);
      final player = _FakePlayerController();
      final client = _FakeOverlayClient();
      final container = _overlayContainer(client, live: live, player: player);
      addTearDown(container.dispose);
      final subscription = container.listen(
        liveOverlayControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _flushMicrotasks();

      await container.read(liveOverlayControllerProvider.notifier).start();

      expect(client.startCalls, 1);
      expect(container.read(liveOverlayControllerProvider).isActive, isTrue);
      var payload = client.published.last;
      expect(payload['type'], 'state');
      expect(payload['locale'], 'es');
      expect(payload['labels'], <String, String>{
        'resolving': 'BUSCANDO',
        'downloading': 'CARGANDO',
        'untitled': 'Sin título',
      });
      expect(payload['accent'], <String, String>{
        'seed': '#3D8BFF',
        'dark': '#1F58B5',
      });
      expect(
        (payload['items']! as List<Object?>).cast<Map<String, Object>>().map(
          (item) => item['id'],
        ),
        ['request-0', 'request-1', 'request-2'],
      );

      player.publish(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          trackId: 'track-1',
          isRemote: true,
          position: Duration(seconds: 30),
          duration: Duration(minutes: 2),
        ),
        liveQueueActive: true,
      );
      await _flushMicrotasks();

      payload = client.published.last;
      expect(payload['progress'], 0.25);
      expect(payload['positionMs'], 30000);
      expect(payload['durationMs'], 120000);

      container
          .read(_testLanguageProvider.notifier)
          .setLanguage(AppLanguage.english);
      await _flushMicrotasks();

      payload = client.published.last;
      expect(payload['locale'], 'en');
      expect(payload['labels'], <String, String>{
        'resolving': 'SEARCHING',
        'downloading': 'LOADING',
        'untitled': 'Untitled',
      });
      expect(client.startCalls, 1);
      final items = (payload['items']! as List<Object?>)
          .cast<Map<String, Object>>();
      expect(items.map((item) => item['id']), ['request-1', 'request-2']);
      expect(items.first['status'], 'playing');

      player.publish(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          trackId: 'track-1',
          isRemote: true,
          position: Duration(minutes: 3),
          duration: Duration(minutes: 2),
        ),
        liveQueueActive: true,
      );
      await _flushMicrotasks();

      payload = client.published.last;
      expect(payload['progress'], 1.0);
      expect(payload['positionMs'], 120000);
      expect(payload['durationMs'], 120000);

      await container.read(liveOverlayControllerProvider.notifier).stop();
      expect(client.stopCalls, 1);
      expect(
        container.read(liveOverlayControllerProvider).status,
        LiveOverlayStatus.inactive,
      );
    },
  );

  test('publishes a resolved cover without delaying server startup', () async {
    final artwork = Completer<String?>();
    final client = _FakeOverlayClient();
    final container = _overlayContainer(
      client,
      live: _FakeLiveController([_item(0)]),
      artworkLoader: (_) => artwork.future,
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      liveOverlayControllerProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await _flushMicrotasks();

    await container.read(liveOverlayControllerProvider.notifier).start();
    var item = _lastItem(client);
    expect(item, isNot(contains('artwork')));

    artwork.complete('data:image/png;base64,cG5n');
    await _flushMicrotasks();
    await _flushMicrotasks();

    item = _lastItem(client);
    expect(item['artwork'], 'data:image/png;base64,cG5n');
  });

  test(
    'localizes a nested Windows permission failure without leaking it',
    () async {
      final client = _FakeOverlayClient()
        ..startError = LocalLiveOverlayServerException(
          'No se pudo iniciar $liveOverlayUrl.',
          LocalOverlayHostsElevationException(
            'Windows could not request permission.',
            const ProcessException(
              'powershell.exe',
              <String>['-EncodedCommand', 'secret-diagnostic-payload'],
              'Access denied',
              5,
            ),
          ),
        );
      final container = _overlayContainer(client);
      addTearDown(container.dispose);
      final subscription = container.listen(
        liveOverlayControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _flushMicrotasks();

      final controller = container.read(liveOverlayControllerProvider.notifier);
      await controller.start();

      var snapshot = container.read(liveOverlayControllerProvider);
      expect(snapshot.status, LiveOverlayStatus.error);
      expect(
        snapshot.error,
        'Windows no pudo configurar el dominio local. Inténtalo de nuevo y '
        'acepta el permiso de administrador.',
      );
      expect(snapshot.error, isNot(contains('ProcessException')));
      expect(snapshot.error, isNot(contains('secret-diagnostic-payload')));

      container
          .read(_testLanguageProvider.notifier)
          .setLanguage(AppLanguage.english);
      await _flushMicrotasks();
      await controller.start();

      snapshot = container.read(liveOverlayControllerProvider);
      expect(
        snapshot.error,
        'Windows could not configure the local domain. Try again and accept the '
        'administrator permission.',
      );
    },
  );

  test(
    'localizes a Windows command timeout before the generic permission error',
    () async {
      final client = _FakeOverlayClient()
        ..startError = const LocalLiveOverlayServerException(
          'Technical wrapper',
          LocalOverlayHostsTimeoutException(
            'Generic elevation wrapper',
            LocalOverlayHostsCommandTimeoutException(
              timeout: Duration(seconds: 30),
              pid: 4812,
            ),
          ),
        );
      final container = _overlayContainer(client);
      addTearDown(container.dispose);
      final subscription = container.listen(
        liveOverlayControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _flushMicrotasks();

      final controller = container.read(liveOverlayControllerProvider.notifier);
      await controller.start();

      var snapshot = container.read(liveOverlayControllerProvider);
      expect(snapshot.status, LiveOverlayStatus.error);
      expect(
        snapshot.error,
        'Windows no mostró o no completó a tiempo la solicitud de permiso. '
        'Vuelve a intentarlo y revisa si el aviso de Control de cuentas de '
        'usuario (UAC) quedó detrás de otra ventana.',
      );
      expect(snapshot.error, isNot(contains('process 4812')));
      expect(snapshot.error, isNot(contains('Technical wrapper')));
      expect(snapshot.error, isNot(contains('Generic elevation wrapper')));

      container
          .read(_testLanguageProvider.notifier)
          .setLanguage(AppLanguage.english);
      await _flushMicrotasks();
      await controller.start();

      snapshot = container.read(liveOverlayControllerProvider);
      expect(
        snapshot.error,
        'Windows did not show or complete the permission request in time. Try '
        'again and check whether the User Account Control (UAC) prompt '
        'appeared behind another window.',
      );
    },
  );

  test(
    'reports a hosts conflict without exposing the server exception',
    () async {
      final client = _FakeOverlayClient()
        ..startError = const LocalLiveOverlayServerException(
          'Technical wrapper',
          LocalOverlayHostsConflictException('Technical conflict details'),
        );
      final container = _overlayContainer(client);
      addTearDown(container.dispose);
      final subscription = container.listen(
        liveOverlayControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _flushMicrotasks();

      await container.read(liveOverlayControllerProvider.notifier).start();

      final snapshot = container.read(liveOverlayControllerProvider);
      expect(snapshot.status, LiveOverlayStatus.error);
      expect(snapshot.error, contains(localLiveOverlayHost));
      expect(snapshot.error, contains('archivo hosts'));
      expect(snapshot.error, isNot(contains('Technical')));
    },
  );

  test('reports actionable Windows overlay startup diagnostics', () async {
    final cases = <({Object error, String expected})>[
      (
        error: const LocalOverlayHostsElevationCancelledException(
          'private cancellation detail',
        ),
        expected:
            'Se canceló el permiso de administrador. La overlay no realizó cambios.',
      ),
      (
        error: const LocalOverlayHostsPolicyException(
          'private applicationPolicyDetail',
        ),
        expected: 'Una política de seguridad de Windows bloqueó',
      ),
      (
        error: const LocalOverlayHostsPowerShellUnavailableException(
          'private PowerShell detail',
        ),
        expected: 'Windows PowerShell 5.1 no está disponible',
      ),
      (
        error: const LocalLiveOverlayVerificationException(
          'private endpoint detail',
        ),
        expected: 'BStream no pudo abrir la overlay por DNS o HTTP',
      ),
      (
        error: const LocalLiveOverlayPortInUseException(
          'private port owner detail',
        ),
        expected: 'Otra aplicación ya está usando el puerto 80',
      ),
      (
        error: const LocalLiveOverlayPortAccessException(
          'private port policy detail',
        ),
        expected: 'Windows bloqueó o reservó el puerto 80',
      ),
    ];

    for (final diagnostic in cases) {
      final client = _FakeOverlayClient()..startError = diagnostic.error;
      final container = _overlayContainer(client);
      final subscription = container.listen(
        liveOverlayControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      await _flushMicrotasks();

      await container.read(liveOverlayControllerProvider.notifier).start();

      final snapshot = container.read(liveOverlayControllerProvider);
      expect(snapshot.status, LiveOverlayStatus.error);
      expect(snapshot.error, contains(diagnostic.expected));
      expect(snapshot.error, isNot(contains('private')));

      subscription.close();
      container.dispose();
    }
  });

  test('a failed stop stays active so it can be retried', () async {
    final client = _FakeOverlayClient();
    final container = _overlayContainer(client);
    addTearDown(container.dispose);
    final subscription = container.listen(
      liveOverlayControllerProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await _flushMicrotasks();
    final controller = container.read(liveOverlayControllerProvider.notifier);
    await controller.start();

    client.stopError = StateError('port busy');
    await controller.stop();
    expect(container.read(liveOverlayControllerProvider).isActive, isTrue);
    expect(
      container.read(liveOverlayControllerProvider).error,
      contains('port busy'),
    );

    client.stopError = null;
    await controller.stop();
    expect(container.read(liveOverlayControllerProvider).isActive, isFalse);
    expect(client.stopCalls, 2);
  });
}

ProviderContainer _overlayContainer(
  _FakeOverlayClient client, {
  _FakeLiveController? live,
  _FakePlayerController? player,
  Future<String?> Function(String)? artworkLoader,
}) {
  return ProviderContainer(
    overrides: [
      tiktokLiveControllerProvider.overrideWith(
        () => live ?? _FakeLiveController(const []),
      ),
      playerControllerProvider.overrideWith(
        () => player ?? _FakePlayerController(),
      ),
      liveOverlayClientProvider.overrideWithValue(client),
      liveOverlayArtworkLoaderProvider.overrideWithValue(
        artworkLoader ?? (_) async => null,
      ),
      liveOverlayAccentProvider.overrideWithValue(AppAccent.blue),
      appStringsProvider.overrideWith(
        (ref) => AppStrings(ref.watch(_testLanguageProvider)),
      ),
    ],
  );
}

Map<String, Object> _lastItem(_FakeOverlayClient client) {
  final items = client.published.last['items']! as List<Object?>;
  return items.single! as Map<String, Object>;
}

LiveQueueItem _item(
  int index, {
  LiveQueueItemStatus status = LiveQueueItemStatus.ready,
  bool resolved = true,
}) {
  return LiveQueueItem(
    id: 'request-$index',
    requestedBy: 'viewer-$index',
    query: 'Song $index',
    commandText: '!play Song $index',
    requestedAt: DateTime(2026, 1, 1, 12, index),
    status: status,
    message: status.name,
    remoteTrack: resolved
        ? TrackInfo(
            id: 'track-$index',
            title: 'Song $index',
            artist: 'Artist $index',
            url: 'https://music.test/$index',
            thumbnailUrl: 'https://img.test/$index.jpg',
          )
        : null,
  );
}

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final _testLanguageProvider =
    NotifierProvider<_TestLanguageController, AppLanguage>(
      _TestLanguageController.new,
    );

class _TestLanguageController extends Notifier<AppLanguage> {
  @override
  AppLanguage build() => AppLanguage.spanish;

  void setLanguage(AppLanguage value) => state = value;
}

class _FakeLiveController extends TikTokLiveController {
  _FakeLiveController(this.initialQueue);

  final List<LiveQueueItem> initialQueue;

  @override
  Future<TikTokLiveState> build() async => TikTokLiveState(
    creatorInput: '@test',
    status: TikTokLiveStatus.connected,
    message: 'Conectado',
    liveQueue: initialQueue,
  );
}

class _FakePlayerController extends PlayerController {
  bool _liveQueueActive = false;

  @override
  bool get isLiveQueueActive => _liveQueueActive;

  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);

  void publish(PlayerSnapshot snapshot, {required bool liveQueueActive}) {
    _liveQueueActive = liveQueueActive;
    state = AsyncData(snapshot);
  }
}

class _FakeOverlayClient implements LiveOverlayClient {
  int startCalls = 0;
  int stopCalls = 0;
  Object? startError;
  Object? stopError;
  final List<Map<String, Object>> published = <Map<String, Object>>[];

  @override
  Future<Uri> start() async {
    startCalls++;
    if (startError case final error?) throw error;
    return Uri.parse(liveOverlayUrl);
  }

  @override
  void publishJson(Object? value) {
    published.add(Map<String, Object>.from(value! as Map));
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (stopError case final error?) throw error;
  }

  @override
  Future<void> dispose() async {}
}
