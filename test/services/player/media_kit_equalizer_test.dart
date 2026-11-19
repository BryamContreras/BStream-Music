import 'package:bstream_music/services/player/media_kit_equalizer.dart';
import 'package:bstream_music/services/player/player_equalizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  const bass = EqualizerSettings(
    enabled: true,
    gainsDb: [6, 3, 0, 0, 0, 0, 0, 0, 0, 0],
  );

  test('native curve uses ten Q=1 bands in floating-point precision', () {
    const curve = EqualizerSettings(
      enabled: true,
      gainsDb: [6, -3, 2, -1, 4, 1, -2, 3, -4, 5],
    );
    final graph = MediaKitEqualizerFilter.graph(curve)!;
    expect(graph, isNot(contains('volume=')));
    for (final frequency in equalizerBandFrequencies) {
      expect(graph, contains('equalizer=f=${frequency.toInt()}:t=q:w=1:g='));
    }
    expect(graph.split('equalizer='), hasLength(11));
    expect(RegExp(':r=f64').allMatches(graph), hasLength(10));
  });

  test('disabled and flat curves have no DSP graph', () {
    expect(MediaKitEqualizerFilter.graph(const EqualizerSettings()), isNull);
    expect(
      MediaKitEqualizerFilter.graph(const EqualizerSettings(enabled: true)),
      isNull,
    );
  });

  test('untrusted gains are normalized before building native commands', () {
    final graph = MediaKitEqualizerFilter.graph(
      EqualizerSettings(
        enabled: true,
        gainsDb: [double.nan, 100, -100, double.infinity, 2, 0, 0, 0, 0, 0],
      ),
    )!;
    expect(graph, isNot(contains('volume=')));
    expect(graph, contains('f=62:t=q:w=1:g=12.000'));
    expect(graph, contains('f=125:t=q:w=1:g=-12.000'));
    expect(graph, isNot(contains('NaN')));
    expect(graph, isNot(contains('Infinity')));
  });

  test(
    'labelled replacement and bypass preserve other audio filters',
    () async {
      final player = _NativeFilters();
      await MediaKitEqualizerFilter.apply(player, bass);
      expect(player.filters, contains('@another-feature:lavfi=[anull]'));
      expect(player.commands.single.take(2), ['af', 'add']);
      expect(player.equalizer, contains('g=6.000:r=f64'));

      const cut = EqualizerSettings(
        enabled: true,
        gainsDb: [-6, -3, 0, 0, 0, 0, 0, 0, 0, 0],
      );
      await MediaKitEqualizerFilter.apply(player, cut);
      expect(player.equalizer, isNot(contains('volume=')));
      expect(player.equalizer, contains('g=-6.000'));
      expect(RegExp('@bstream-eq:').allMatches(player.filters), hasLength(1));

      await MediaKitEqualizerFilter.apply(player, const EqualizerSettings());
      expect(player.filters, '@another-feature:lavfi=[anull]');
      expect(player.commands.last, ['af', 'remove', '@bstream-eq']);
      final count = player.commands.length;
      await MediaKitEqualizerFilter.apply(
        player,
        const EqualizerSettings(enabled: true),
      );
      expect(player.commands.length, count);
    },
  );

  test(
    'detects native silent rejection and removes only its own stale curve',
    () async {
      final player = _NativeFilters();
      await MediaKitEqualizerFilter.apply(player, bass);
      player.rejectAdds = true;
      await expectLater(
        MediaKitEqualizerFilter.apply(
          player,
          const EqualizerSettings(
            enabled: true,
            gainsDb: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
          ),
        ),
        throwsStateError,
      );
      expect(player.filters, '@another-feature:lavfi=[anull]');
    },
  );

  test('similar labels are not treated as the owned filter', () async {
    final player = _NativeFilters()..other = '@bstream-eq-other:lavfi=[anull]';
    await MediaKitEqualizerFilter.apply(player, const EqualizerSettings());
    expect(player.commands, isEmpty);
    expect(player.filters, '@bstream-eq-other:lavfi=[anull]');
  });
}

class _NativeFilters implements NativePlayer {
  String other = '@another-feature:lavfi=[anull]';
  String? equalizer;
  bool rejectAdds = false;
  final commands = <List<String>>[];

  String get filters => [other, ?equalizer].join(',');

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    expect(property, 'af');
    return filters;
  }

  @override
  Future<void> command(
    List<String> command, {
    bool waitForInitialization = true,
  }) async {
    commands.add(List.of(command));
    expect(command.first, 'af');
    if (command[1] == 'add' && !rejectAdds) equalizer = command[2];
    if (command[1] == 'remove') {
      expect(command[2], '@bstream-eq');
      equalizer = null;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
