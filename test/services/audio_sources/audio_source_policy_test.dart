import 'dart:async';

import 'package:bstream_music/services/audio_sources/audio_network_monitor.dart';
import 'package:bstream_music/services/audio_sources/audio_source_policy.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop uses one saved quality on every reported connection', () {
    const high = AudioSourcePolicy(useSingleProfile: true);
    const standard = AudioSourcePolicy(
      useSingleProfile: true,
      wifiAudioQuality: AudioQualityProfile.standard,
      mobileAudioQuality: AudioQualityProfile.high,
    );
    const disabled = AudioSourcePolicy(
      useSingleProfile: true,
      jioSaavnEnabled: false,
    );
    for (final network in AudioNetworkKind.values) {
      expect(high.profileFor(network), AudioQualityProfile.high);
      expect(standard.profileFor(network), AudioQualityProfile.standard);
      expect(disabled.profileFor(network), AudioQualityProfile.standard);
    }
    expect(high.cacheKey, isNot(const AudioSourcePolicy().cacheKey));
  });

  test('defaults allow Wi-Fi upgrades and conserve mobile/unknown data', () {
    const policy = AudioSourcePolicy();
    expect(policy.allowsUpgrade(AudioNetworkKind.wifi), isTrue);
    for (final network in [
      AudioNetworkKind.mobile,
      AudioNetworkKind.offline,
      AudioNetworkKind.unknown,
    ]) {
      expect(policy.allowsUpgrade(network), isFalse);
    }
    const disabled = AudioSourcePolicy(jioSaavnEnabled: false);
    expect(disabled.allowsUpgrade(AudioNetworkKind.wifi), isFalse);
    const mobile = AudioSourcePolicy(
      wifiAudioQuality: AudioQualityProfile.standard,
      mobileAudioQuality: AudioQualityProfile.high,
    );
    expect(mobile.allowsUpgrade(AudioNetworkKind.mobile), isTrue);
    expect(mobile.allowsUpgrade(AudioNetworkKind.wifi), isFalse);
  });

  test(
    'wired networks use Wi-Fi profile and ambiguous/cellular stay cautious',
    () {
      expect(
        audioNetworkForConnections([ConnectivityResult.ethernet]),
        AudioNetworkKind.wifi,
      );
      expect(
        audioNetworkForConnections([
          ConnectivityResult.wifi,
          ConnectivityResult.mobile,
        ]),
        AudioNetworkKind.mobile,
      );
      expect(
        audioNetworkForConnections([ConnectivityResult.vpn]),
        AudioNetworkKind.unknown,
      );
      expect(
        audioNetworkForConnections([
          ConnectivityResult.vpn,
          ConnectivityResult.mobile,
        ]),
        AudioNetworkKind.mobile,
      );
      expect(
        audioNetworkForConnections([ConnectivityResult.none]),
        AudioNetworkKind.offline,
      );
      expect(audioNetworkForConnections([]), AudioNetworkKind.unknown);
    },
  );

  test(
    'coalesces reads and refreshes after the short session snapshot expires',
    () async {
      var now = DateTime(2026);
      var reads = 0;
      final pending = Completer<AudioNetworkKind>();
      final monitor = AudioNetworkMonitor(
        reader: () {
          reads++;
          return pending.future;
        },
        changes: const Stream.empty(),
        clock: () => now,
      );
      addTearDown(monitor.dispose);
      final first = monitor.current();
      final second = monitor.current();
      expect(identical(first, second), isTrue);
      pending.complete(AudioNetworkKind.wifi);
      expect(await first, AudioNetworkKind.wifi);
      expect(await monitor.current(), AudioNetworkKind.wifi);
      expect(reads, 1);
      now = now.add(const Duration(seconds: 4));
      await monitor.current();
      expect(reads, 2);
    },
  );

  test(
    'a new cellular event overrides an older in-flight Wi-Fi read',
    () async {
      final pending = Completer<AudioNetworkKind>();
      final events = StreamController<AudioNetworkKind>(sync: true);
      final monitor = AudioNetworkMonitor(
        reader: () => pending.future,
        changes: events.stream,
      );
      addTearDown(() async {
        await monitor.dispose();
        await events.close();
      });
      final reading = monitor.current();
      events.add(AudioNetworkKind.mobile);
      pending.complete(AudioNetworkKind.wifi);
      expect(await reading, AudioNetworkKind.mobile);
      expect(monitor.lastKnownKind, AudioNetworkKind.mobile);
    },
  );

  test(
    'missing or failed platform information never opts into high data use',
    () async {
      final monitor = AudioNetworkMonitor(
        reader: () => Future.error(StateError('No platform implementation')),
        changes: const Stream.empty(),
      );
      expect(await monitor.current(), AudioNetworkKind.unknown);
      await monitor.dispose();
      expect(await monitor.current(), AudioNetworkKind.unknown);
    },
  );

  testWidgets(
    'a late initial platform result restores Wi-Fi after the caller timeout',
    (tester) async {
      final pending = Completer<AudioNetworkKind>();
      final monitor = AudioNetworkMonitor(
        reader: () => pending.future,
        changes: const Stream.empty(),
      );
      addTearDown(monitor.dispose);
      final first = monitor.current();
      await tester.pump(const Duration(seconds: 1));
      expect(await first, AudioNetworkKind.unknown);
      expect(monitor.lastKnownKind, AudioNetworkKind.unknown);

      pending.complete(AudioNetworkKind.wifi);
      await tester.pump();
      expect(monitor.lastKnownKind, AudioNetworkKind.wifi);
      expect(await monitor.current(), AudioNetworkKind.wifi);
    },
  );

  testWidgets(
    'a late timed-out Wi-Fi read never overwrites a newer cellular event',
    (tester) async {
      final pending = Completer<AudioNetworkKind>();
      final events = StreamController<AudioNetworkKind>(sync: true);
      final monitor = AudioNetworkMonitor(
        reader: () => pending.future,
        changes: events.stream,
      );
      addTearDown(() async {
        await monitor.dispose();
        await events.close();
      });
      final first = monitor.current();
      await tester.pump(const Duration(seconds: 1));
      expect(await first, AudioNetworkKind.unknown);
      events.add(AudioNetworkKind.mobile);
      pending.complete(AudioNetworkKind.wifi);
      await tester.pump();
      expect(monitor.lastKnownKind, AudioNetworkKind.mobile);
    },
  );

  test('a disposed monitor discards its late platform answer', () async {
    final pending = Completer<AudioNetworkKind>();
    final monitor = AudioNetworkMonitor(
      reader: () => pending.future,
      changes: const Stream.empty(),
    );
    expect(await monitor.current(), AudioNetworkKind.unknown);
    await monitor.dispose();
    pending.complete(AudioNetworkKind.wifi);
    await Future<void>.delayed(Duration.zero);
    expect(monitor.lastKnownKind, AudioNetworkKind.unknown);
    expect(monitor.canRefreshAfter(Duration.zero), isFalse);
  });
}
