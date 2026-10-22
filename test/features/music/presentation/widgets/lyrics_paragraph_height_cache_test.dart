import 'package:bstream_music/features/music/presentation/widgets/lyrics_line_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const original =
      'The original line remains the same when a companion arrives';
  const style = TextStyle(fontSize: 24, height: 1.16);

  double measure(
    LyricsParagraphHeightCache cache, {
    String text = original,
    TextStyle textStyle = style,
    double width = 240,
    TextScaler scaler = TextScaler.noScaling,
    TextDirection direction = TextDirection.ltr,
    Locale? locale,
    TextHeightBehavior? heightBehavior,
  }) => cache.measure(
    text: text,
    style: textStyle,
    maxWidth: width,
    textScaler: scaler,
    textDirection: direction,
    locale: locale,
    textHeightBehavior: heightBehavior,
  );

  test('companion arrival reuses original shaping with identical geometry', () {
    final cache = LyricsParagraphHeightCache();
    addTearDown(cache.dispose);
    final originalHeight = measure(cache);
    final companionHeight = measure(
      cache,
      text: 'Una traducción que llega después del texto original',
      textStyle: style.copyWith(fontSize: 18),
    );
    expect(companionHeight, greaterThan(0));
    expect(cache.debugLayoutCount, 2);
    expect(measure(cache), originalHeight);
    expect(cache.debugLayoutCount, 2);
  });

  test('width, typography and accessibility changes retain exact heights', () {
    final cache = LyricsParagraphHeightCache();
    addTearDown(cache.dispose);
    final wide = measure(cache, width: 480);
    final narrow = measure(cache, width: 120);
    final scaled = measure(cache, scaler: const TextScaler.linear(1.6));
    expect(narrow, greaterThan(wide));
    expect(scaled, greaterThan(measure(cache)));
    final layouts = cache.debugLayoutCount;
    measure(cache, direction: TextDirection.rtl);
    measure(cache, locale: const Locale('ja'));
    measure(
      cache,
      heightBehavior: const TextHeightBehavior(applyHeightToFirstAscent: false),
    );
    measure(cache, textStyle: style.copyWith(letterSpacing: 3));
    expect(cache.debugLayoutCount, layouts + 4);

    final painter = TextPainter(
      text: const TextSpan(text: original, style: style),
      textDirection: TextDirection.ltr,
      textScaler: const TextScaler.linear(1.6),
    )..layout(maxWidth: 240);
    expect(scaled, painter.height);
    painter.dispose();
  });

  test(
    'least recently used heights and retained text have independent bounds',
    () {
      final cache = LyricsParagraphHeightCache(
        maximumEntries: 2,
        maximumTextCodeUnits: 12,
      );
      addTearDown(cache.dispose);
      measure(cache, text: 'first');
      measure(cache, text: 'second');
      measure(cache, text: 'first');
      measure(cache, text: 'third');
      expect(cache.debugEntryCount, 2);
      expect(cache.debugRetainedTextCodeUnits, 10);
      expect(cache.debugLayoutCount, 3);
      measure(cache, text: 'second');
      expect(cache.debugLayoutCount, 4);
      expect(cache.debugRetainedTextCodeUnits, lessThanOrEqualTo(12));

      measure(cache, text: 'longer than the retained text budget');
      measure(cache, text: 'longer than the retained text budget');
      expect(cache.debugLayoutCount, 6);
      expect(cache.debugEntryCount, 2);
      expect(cache.debugRetainedTextCodeUnits, lessThanOrEqualTo(12));
    },
  );

  testWidgets('memory pressure releases cached text and heights', (
    tester,
  ) async {
    final cache = LyricsParagraphHeightCache();
    addTearDown(cache.dispose);
    final height = measure(cache);
    expect(cache.debugEntryCount, 1);
    tester.binding.handleMemoryPressure();
    expect(cache.debugEntryCount, 0);
    expect(cache.debugRetainedTextCodeUnits, 0);
    expect(measure(cache), height);
    expect(cache.debugLayoutCount, 2);
  });

  testWidgets('font availability changes invalidate prior shaping metrics', (
    tester,
  ) async {
    final cache = LyricsParagraphHeightCache();
    addTearDown(cache.dispose);
    final height = measure(cache);
    await tester.binding.handleSystemMessage({'type': 'fontsChange'});
    expect(cache.debugEntryCount, 0);
    expect(measure(cache), height);
    expect(cache.debugLayoutCount, 2);
  });
}
