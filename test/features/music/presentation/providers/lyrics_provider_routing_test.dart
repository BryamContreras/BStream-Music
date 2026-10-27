import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/lyrics/lyrics_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _lookup = LyricsLookup(
  title: 'Example',
  artist: 'Artist',
  duration: Duration(seconds: 238),
  sourceId: 'track',
);

void main() {
  for (var mask = 0; mask < 8; mask++) {
    test(
      'selection mask $mask constructs and queries only enabled providers',
      () async {
        final enabled = {
          for (final provider in LyricsProvider.values)
            if (mask & (1 << provider.index) != 0) provider,
        };
        final harness = _Harness(enabled);
        addTearDown(harness.dispose);
        await harness.ready();
        final sub = harness.container.listen(
          lyricsProvider(_lookup),
          (_, _) {},
        );
        addTearDown(sub.close);

        expect(
          await harness.container.read(lyricsProvider(_lookup).future),
          isNull,
        );
        expect(
          harness.calls,
          LyricsProvider.values.where(enabled.contains).toList(),
        );
        expect(harness.constructed.toSet(), enabled);
      },
    );
  }

  test(
    'plain Better Lyrics and instrumental LyricsPlus fall through to synced LRCLIB',
    () async {
      final harness = _Harness(defaultLyricsProviders);
      addTearDown(harness.dispose);
      harness.services[LyricsProvider.betterLyrics]!.result = _document(
        'Better Lyrics',
        plain: true,
      );
      harness.services[LyricsProvider.youLyPlus]!.result = _document(
        'LyricsPlus',
        instrumental: true,
      );
      final actual = _document('LRCLIB');
      harness.services[LyricsProvider.lrclib]!.result = actual;
      await harness.ready();

      expect(
        await harness.container.read(lyricsProvider(_lookup).future),
        same(actual),
      );
      expect(harness.calls, [
        LyricsProvider.betterLyrics,
        LyricsProvider.youLyPlus,
        LyricsProvider.lrclib,
      ]);
    },
  );

  test(
    'valid synchronized Better Lyrics stops lower-priority requests',
    () async {
      final harness = _Harness(defaultLyricsProviders);
      addTearDown(harness.dispose);
      final better = _document('Better Lyrics');
      harness.services[LyricsProvider.betterLyrics]!.result = better;
      harness.services[LyricsProvider.youLyPlus]!.result = _document(
        'LyricsPlus',
      );
      harness.services[LyricsProvider.lrclib]!.result = _document('LRCLIB');
      await harness.ready();

      expect(
        await harness.container.read(lyricsProvider(_lookup).future),
        same(better),
      );
      expect(harness.calls, [LyricsProvider.betterLyrics]);
    },
  );

  test(
    'persisted selection is known before any provider can be queried',
    () async {
      final gate = Completer<SettingsState>();
      final harness = _Harness(defaultLyricsProviders, initial: gate.future);
      final actual = _document('LyricsPlus');
      harness.services[LyricsProvider.youLyPlus]!.result = actual;
      addTearDown(harness.dispose);
      final sub = harness.container.listen(lyricsProvider(_lookup), (_, _) {});
      addTearDown(sub.close);
      await harness.container.pump();
      expect(harness.calls, isEmpty);
      expect(harness.constructed, isEmpty);

      gate.complete(_settings({LyricsProvider.youLyPlus}));
      expect(
        await harness.container.read(lyricsProvider(_lookup).future),
        same(actual),
      );
      expect(harness.calls, [LyricsProvider.youLyPlus]);
      expect(harness.constructed, [LyricsProvider.youLyPlus]);
    },
  );

  test(
    'unrelated settings do not rebuild or requery lyrics services',
    () async {
      final harness = _Harness(defaultLyricsProviders);
      addTearDown(harness.dispose);
      harness.services[LyricsProvider.betterLyrics]!.result = _document(
        'Better Lyrics',
      );
      await harness.ready();
      final sub = harness.container.listen(lyricsProvider(_lookup), (_, _) {});
      addTearDown(sub.close);
      await harness.container.read(lyricsProvider(_lookup).future);
      final service = harness.container.read(lyricsServiceProvider);
      harness.settings.setAlignment(LyricsTextAlignment.centered);
      await harness.container.pump();

      expect(harness.container.read(lyricsServiceProvider), same(service));
      expect(harness.calls, [LyricsProvider.betterLyrics]);
      expect(
        harness.services.values.every((service) => service.disposeCalls == 0),
        isTrue,
      );
    },
  );

  test(
    'changing providers recomputes the current song and releases only disabled clients',
    () async {
      final harness = _Harness(defaultLyricsProviders);
      addTearDown(harness.dispose);
      harness.services[LyricsProvider.lrclib]!.result = _document(
        'LRCLIB',
        instrumental: true,
      );
      final lyricsPlus = _document('LyricsPlus');
      harness.services[LyricsProvider.youLyPlus]!.result = lyricsPlus;
      final better = _document('Better Lyrics');
      harness.services[LyricsProvider.betterLyrics]!.result = better;
      await harness.ready();
      final sub = harness.container.listen(lyricsProvider(_lookup), (_, _) {});
      addTearDown(sub.close);
      expect(
        (await harness.container.read(
          lyricsProvider(_lookup).future,
        ))?.provider,
        'Better Lyrics',
      );

      harness.settings.select({
        LyricsProvider.youLyPlus,
        LyricsProvider.lrclib,
      });
      await harness.container.pump();
      expect(
        await harness.container.read(lyricsProvider(_lookup).future),
        same(lyricsPlus),
      );
      await harness.container.pump();
      expect(harness.services[LyricsProvider.youLyPlus]!.disposeCalls, 0);
      expect(harness.services[LyricsProvider.lrclib]!.disposeCalls, 0);
      expect(harness.services[LyricsProvider.betterLyrics]!.disposeCalls, 1);
    },
  );

  test('disabling a pending provider stops its old fallback chain', () async {
    final gate = Completer<LyricsDocument?>();
    final harness = _Harness(defaultLyricsProviders);
    addTearDown(harness.dispose);
    harness.services[LyricsProvider.betterLyrics]!.pending = gate.future;
    final lrclib = _document('LRCLIB');
    harness.services[LyricsProvider.lrclib]!.result = lrclib;
    await harness.ready();
    final sub = harness.container.listen(lyricsProvider(_lookup), (_, _) {});
    addTearDown(sub.close);
    final pending = harness.container.read(lyricsProvider(_lookup).future);
    unawaited(pending.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    await harness.services[LyricsProvider.betterLyrics]!.started.future.timeout(
      const Duration(seconds: 2),
    );
    expect(harness.calls, [LyricsProvider.betterLyrics]);

    harness.settings.select({LyricsProvider.lrclib});
    await harness.container.pump();
    expect(
      await harness.container.read(lyricsProvider(_lookup).future),
      same(lrclib),
    );
    gate.complete(null);
    await harness.container.pump();
    expect(harness.services[LyricsProvider.youLyPlus]!.findCalls, 0);
    expect(harness.services[LyricsProvider.betterLyrics]!.disposeCalls, 1);
    expect(harness.calls, [LyricsProvider.betterLyrics, LyricsProvider.lrclib]);
  });

  test(
    'manual choices clear only when providers change, not when alignment changes',
    () async {
      final harness = _Harness(defaultLyricsProviders);
      addTearDown(harness.dispose);
      await harness.ready();
      await harness.container.read(playerControllerProvider.future);
      final selection = harness.container.read(
        selectedLyricsControllerProvider.notifier,
      );
      final chosen = _document('LyricsPlus');
      selection.select(chosen);
      harness.settings.setAlignment(LyricsTextAlignment.centered);
      await harness.container.pump();
      expect(
        harness.container.read(selectedLyricsControllerProvider),
        same(chosen),
      );

      harness.settings.select({LyricsProvider.lrclib});
      await harness.container.pump();
      expect(harness.container.read(selectedLyricsControllerProvider), isNull);
    },
  );

  test(
    'disabling every provider releases pending clients without another request',
    () async {
      final gate = Completer<LyricsDocument?>();
      final harness = _Harness(defaultLyricsProviders);
      addTearDown(harness.dispose);
      harness.services[LyricsProvider.betterLyrics]!.pending = gate.future;
      await harness.ready();
      final sub = harness.container.listen(lyricsProvider(_lookup), (_, _) {});
      addTearDown(sub.close);
      final pending = harness.container.read(lyricsProvider(_lookup).future);
      unawaited(
        pending.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      await harness.services[LyricsProvider.betterLyrics]!.started.future
          .timeout(const Duration(seconds: 2));
      harness.settings.select({});
      await harness.container.pump();
      expect(
        await harness.container.read(lyricsProvider(_lookup).future),
        isNull,
      );
      await harness.container.pump();
      expect(
        harness.services.values.every((service) => service.disposeCalls == 1),
        isTrue,
      );
      gate.complete(null);
      await harness.container.pump();
      expect(harness.calls, [LyricsProvider.betterLyrics]);
    },
  );

  for (final enabled in [
    <LyricsProvider>{},
    {LyricsProvider.youLyPlus},
  ]) {
    test('manual and similar lyrics respect selection $enabled', () async {
      final harness = _Harness(enabled);
      addTearDown(harness.dispose);
      await harness.ready();
      await harness.container.read(similarLyricsProvider(_lookup).future);
      await harness.container.read(
        manualLyricsSearchProvider((
          title: 'Manual title',
          context: _lookup,
        )).future,
      );

      for (final provider in LyricsProvider.values) {
        final expected = enabled.contains(provider) ? 1 : 0;
        expect(harness.services[provider]!.similarCalls, expected);
        expect(harness.services[provider]!.manualCalls, expected);
      }
    });
  }
}

SettingsState _settings(Set<LyricsProvider> enabled) => SettingsState(
  downloadDirectory: 'unused-test-directory',
  language: AppLanguage.english,
  enabledLyricsProviders: enabled,
);

LyricsDocument _document(
  String provider, {
  bool instrumental = false,
  bool plain = false,
}) => LyricsDocument(
  provider: provider,
  providerId: 'example',
  trackName: 'Example',
  artistName: 'Artist',
  duration: _lookup.duration,
  instrumental: instrumental,
  plainLyrics: instrumental
      ? null
      : 'Synthetic first line\nSynthetic second line\nSynthetic final line',
  lines: instrumental || plain
      ? const []
      : const [
          LyricLine(
            timestamp: Duration(seconds: 5),
            text: 'Synthetic first line',
          ),
          LyricLine(
            timestamp: Duration(seconds: 100),
            text: 'Synthetic second line',
          ),
          LyricLine(
            timestamp: Duration(seconds: 220),
            text: 'Synthetic final line',
          ),
        ],
);

class _Harness {
  _Harness(Set<LyricsProvider> enabled, {Future<SettingsState>? initial}) {
    settings = _Settings(enabled, initial);
    services = {
      for (final provider in LyricsProvider.values)
        provider: _Service(() => calls.add(provider)),
    };
    container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(() => settings),
        playerControllerProvider.overrideWith(_Player.new),
        lrclibLyricsServiceProvider.overrideWith(
          (ref) => create(LyricsProvider.lrclib, ref),
        ),
        youLyPlusLyricsServiceProvider.overrideWith(
          (ref) => create(LyricsProvider.youLyPlus, ref),
        ),
        betterLyricsServiceProvider.overrideWith(
          (ref) => create(LyricsProvider.betterLyrics, ref),
        ),
      ],
    );
  }

  late final ProviderContainer container;
  late final _Settings settings;
  late final Map<LyricsProvider, _Service> services;
  final calls = <LyricsProvider>[];
  final constructed = <LyricsProvider>[];

  LyricsService create(LyricsProvider provider, Ref ref) {
    constructed.add(provider);
    final service = services[provider]!;
    ref.onDispose(service.dispose);
    return service;
  }

  Future<SettingsState> ready() =>
      container.read(settingsControllerProvider.future);
  void dispose() => container.dispose();
}

class _Settings extends SettingsController {
  _Settings(this.enabled, this.initial);
  final Set<LyricsProvider> enabled;
  final Future<SettingsState>? initial;

  @override
  Future<SettingsState> build() async => initial ?? _settings(enabled);

  void select(Set<LyricsProvider> selection) => state = AsyncData(
    state.requireValue.copyWith(enabledLyricsProviders: selection),
  );
  void setAlignment(LyricsTextAlignment alignment) => state = AsyncData(
    state.requireValue.copyWith(lyricsTextAlignment: alignment),
  );
}

class _Player extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => const PlayerSnapshot(
    status: PlayerStatus.playing,
    trackId: 'track',
    title: 'Example',
    artist: 'Artist',
  );
}

class _Service implements LyricsService {
  _Service(this.onFind);
  final void Function() onFind;
  LyricsDocument? result;
  Future<LyricsDocument?>? pending;
  int findCalls = 0;
  int similarCalls = 0;
  int manualCalls = 0;
  int disposeCalls = 0;
  final started = Completer<void>();

  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) async {
    findCalls++;
    if (!started.isCompleted) started.complete();
    onFind();
    return pending ?? result;
  }

  @override
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  }) async {
    similarCalls++;
    return const [];
  }

  @override
  Future<List<LyricsCandidate>> searchLyricsByTitle(
    String title, {
    required LyricsLookup context,
    int limit = 8,
  }) async {
    manualCalls++;
    return const [];
  }

  @override
  void dispose() => disposeCalls++;
}
