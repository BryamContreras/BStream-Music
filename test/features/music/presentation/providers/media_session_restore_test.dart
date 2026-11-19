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

  for (final action in ['repeat', 'favorite']) {
    test('a cold media $action waits for the restored track', () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final callbacks = fixture.session.callbacks!;
      final invoke = action == 'repeat'
          ? callbacks.cycleRepeatMode
          : callbacks.toggleFavorite;
      expect(invoke, isNotNull);
      final pending = invoke!();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.controller.calls, isEmpty);

      fixture.completeRestore();
      await pending;

      expect(fixture.controller.calls, ['$action:restored-track']);
    });
  }

  test(
    'favorite changes update controls without replacing track or queue',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      fixture.container.read(playbackQueueProvider.notifier).replace(const [
        PlaybackQueueEntry(
          id: 'restored-track',
          title: 'Restored track',
          artist: 'BStream Music',
          isRemote: false,
        ),
        PlaybackQueueEntry(
          id: 'next-track',
          title: 'Next track',
          artist: 'BStream Music',
          isRemote: false,
        ),
      ], 0);
      fixture.completeRestore();
      await fixture.container.read(playerControllerProvider.future);
      await fixture.flush();
      final initial = fixture.session.states.last;
      final initialUpdateCount = fixture.session.states.length;
      expect(initial.isFavorite, isFalse);

      fixture.container.read(_favoriteIdsProvider.notifier).replace({
        'restored-track',
      });
      await fixture.flush();
      expect(fixture.session.states.length, greaterThan(initialUpdateCount));
      final favorite = fixture.session.states.last;
      expect(favorite.isFavorite, isTrue);
      expect(favorite.snapshot, same(initial.snapshot));
      expect(favorite.queue, same(initial.queue));
      expect(favorite.currentIndex, initial.currentIndex);

      fixture.container.read(_favoriteIdsProvider.notifier).replace({
        'other-track',
      });
      await fixture.flush();
      final removed = fixture.session.states.last;
      expect(removed.isFavorite, isFalse);
      expect(removed.snapshot, same(initial.snapshot));
      expect(removed.queue, same(initial.queue));
      expect(fixture.controller.calls, isEmpty);
    },
  );

  test('notification control labels follow every supported language', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.completeRestore();
    await fixture.container.read(playerControllerProvider.future);
    await fixture.flush();
    final initial = fixture.session.states.last;

    for (final language in AppLanguage.values) {
      fixture.container.read(_languageProvider.notifier).select(language);
      await fixture.flush();
      final published = fixture.session.states.last;
      final strings = AppStrings(language);
      expect(
        published.controlLabels,
        DesktopMediaControlLabels(
          repeatQueue: strings.repeatQueue,
          repeatOne: strings.repeatOne,
          disableRepeat: strings.disableRepeat,
          addToFavorites: strings.addToFavorites,
          removeFromFavorites: strings.removeFromFavorites,
        ),
        reason: language.code,
      );
      expect(published.snapshot, same(initial.snapshot));
      expect(published.queue, same(initial.queue));
    }
    expect(fixture.controller.calls, isEmpty);
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
        favoriteTrackIdsProvider.overrideWith(
          (ref) => ref.watch(_favoriteIdsProvider),
        ),
        appStringsProvider.overrideWith(
          (ref) => AppStrings(ref.watch(_languageProvider)),
        ),
      ],
    );
    // The app watches this provider for its whole lifetime. Keep an active
    // subscription here too: Riverpod pauses dependency listeners after a
    // standalone read, so later favorite/language changes would be deferred.
    sessionSubscription = container.listen(
      desktopMediaSessionProvider,
      (_, _) {},
      fireImmediately: true,
    );
  }

  final restoration = Completer<PlayerSnapshot>();
  final session = _Session();
  late final _RestoringController controller;
  late final ProviderContainer container;
  late final ProviderSubscription<DesktopMediaSession?> sessionSubscription;

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

  Future<void> flush() async {
    await container.pump();
    await Future<void>.delayed(Duration.zero);
  }

  void dispose() {
    sessionSubscription.close();
    container.dispose();
  }
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

  @override
  void cycleRepeatMode() => calls.add('repeat:${state.requireValue.trackId}');

  @override
  Future<bool> toggleCurrentFavorite() async {
    calls.add('favorite:${state.requireValue.trackId}');
    return true;
  }
}

final _favoriteIdsProvider = NotifierProvider<_FavoriteIds, Set<String>>(
  _FavoriteIds.new,
);

class _FavoriteIds extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void replace(Set<String> ids) => state = Set<String>.unmodifiable(ids);
}

final _languageProvider = NotifierProvider<_Language, AppLanguage>(
  _Language.new,
);

class _Language extends Notifier<AppLanguage> {
  @override
  AppLanguage build() => AppLanguage.spanish;

  void select(AppLanguage language) => state = language;
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
