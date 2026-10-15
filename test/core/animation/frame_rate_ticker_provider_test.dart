import 'package:bstream_music/core/animation/frame_rate_ticker_provider.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('parks callbacks between decorative ticks at 120 Hz', (
    tester,
  ) async {
    final provider = FrameRateTickerProvider()..setDisplayRefreshRate(120);
    final timestamps = <Duration>[];
    final ticker = provider.createTicker(timestamps.add)..start();
    await tester.pump();
    expect(timestamps, hasLength(1));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(microseconds: 8333));
    expect(timestamps, hasLength(1));
    await tester.pump(const Duration(microseconds: 8334));
    expect(timestamps, hasLength(2));
    expect(timestamps.last, const Duration(microseconds: 16667));
    ticker.dispose();
    provider.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('several clocks share a wake and cancel safely', (tester) async {
    final first = FrameRateTickerProvider(maxFramesPerSecond: 30);
    final second = FrameRateTickerProvider(maxFramesPerSecond: 30);
    var firstCount = 0;
    var secondCount = 0;
    final firstTicker = first.createTicker((_) => firstCount++)..start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 5));
    final secondTicker = second.createTicker((_) => secondCount++)..start();
    await tester.pump();
    expect(firstCount, 1);
    expect(secondCount, 1);
    await tester.pump(const Duration(milliseconds: 21));
    expect(firstCount, 2);
    expect(secondCount, 2);
    firstTicker.stop();
    second.enabled = false;
    await tester.pump(const Duration(seconds: 1));
    expect(firstCount, 2);
    expect(secondCount, 2);
    second.enabled = true;
    await tester.pump();
    expect(secondCount, 3);
    firstTicker.dispose();
    secondTicker.dispose();
    first.dispose();
    second.dispose();
  });

  testWidgets('ordinary 60 Hz frames and cancellation keep Ticker semantics', (
    tester,
  ) async {
    final provider = FrameRateTickerProvider();
    var ticks = 0;
    final ticker = provider.createTicker((_) => ticks++);
    final future = ticker.start();
    final canceled = expectLater(
      future.orCancel,
      throwsA(isA<TickerCanceled>()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(ticks, 2);
    ticker.stop(canceled: true);
    await canceled;
    await tester.pump(const Duration(seconds: 1));
    expect(ticks, 2);
    ticker.dispose();
    provider.dispose();
  });
}
