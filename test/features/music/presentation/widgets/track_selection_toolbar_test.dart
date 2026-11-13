import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/track_selection_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/track_selection_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _scope = 'selection-capsule-test';
const _tracks = <TrackInfo>[
  TrackInfo(id: 'one', title: 'One', artist: 'Artist', url: 'https://test/one'),
  TrackInfo(id: 'two', title: 'Two', artist: 'Artist', url: 'https://test/two'),
  TrackInfo(
    id: 'three',
    title: 'Three',
    artist: 'Artist',
    url: 'https://test/three',
  ),
  TrackInfo(
    id: 'four',
    title: 'Four',
    artist: 'Artist',
    url: 'https://test/four',
  ),
];

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'centers $brightness selection text at scale $scale without crowding actions',
        (tester) async {
          await _mount(tester, brightness: brightness, textScale: scale);
          final toolbar = find.byKey(const ValueKey('test-selection-toolbar'));
          final count = find.byKey(const ValueKey('test-selection-count'));
          final add = find.byKey(
            const ValueKey('test-selection-add-to-playlist'),
          );
          final download = find.byKey(
            const ValueKey('test-selection-download'),
          );
          final toolbarRect = tester.getRect(toolbar);
          final countRect = tester.getRect(count);
          expect(countRect.center.dy, closeTo(toolbarRect.center.dy, 0.5));
          expect(countRect.left, greaterThan(toolbarRect.left));
          expect(countRect.right, lessThan(tester.getRect(add).left));
          expect(tester.getSize(add), const Size.square(48));
          expect(tester.getSize(download), const Size.square(48));
          expect(add.hitTestable(), findsOneWidget);
          expect(download.hitTestable(), findsOneWidget);
          final theme = Theme.of(tester.element(count));
          final text = tester.widget<Text>(count);
          expect(text.style!.color, theme.colorScheme.onSurface);
          expect(text.style!.fontSize, theme.textTheme.titleSmall!.fontSize);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('long scaled counts truncate while preserving action targets', (
    tester,
  ) async {
    await _mount(tester, width: 220, textScale: 2);
    final count = find.byKey(const ValueKey('test-selection-count'));
    expect(
      tester.renderObject<RenderParagraph>(count).didExceedMaxLines,
      isTrue,
    );
    expect(tester.widget<Text>(count).data, '4 canciones seleccionadas');
    expect(
      find.byKey(const ValueKey('test-selection-download')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the standard selection header still clears with its close action',
    (tester) async {
      final container = await _mount(tester, width: 320, showCloseButton: true);
      final close = find.byKey(const ValueKey('test-selection-close'));
      expect(tester.getSize(close), const Size.square(48));
      await tester.tap(close);
      await tester.pump();
      expect(container.read(trackSelectionProvider(_scope)).active, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  double width = 270,
  bool showCloseButton = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
  );
  final selection = container.read(trackSelectionProvider(_scope));
  for (final track in _tracks) {
    selection.select(track);
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(Duration.zero);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: 48,
              child: TrackSelectionToolbar(
                scope: _scope,
                tracks: _tracks,
                keyPrefix: 'test-selection',
                showCloseButton: showCloseButton,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // ProviderContainer was created before Flutter attached its frame scheduler.
  // Flush its zero-duration auto-dispose task as well as the widget frame.
  await tester.pump(Duration.zero);
  return container;
}
