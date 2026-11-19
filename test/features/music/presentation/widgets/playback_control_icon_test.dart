import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/playback_control_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'loading animates in place and releases its ticker after playback resumes',
    (tester) async {
      final state = ValueNotifier((loading: false, playing: false));
      addTearDown(state.dispose);
      await tester.pumpWidget(_harness(state));
      await tester.pumpAndSettle();
      final icon = find.byType(PlaybackControlIcon);
      final bounds = tester.getRect(icon);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      state.value = (loading: true, playing: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final spinner = find.byKey(const ValueKey('playback-loading-indicator'));
      expect(spinner, findsOneWidget);
      expect(tester.widget<CircularProgressIndicator>(spinner).value, isNull);
      expect(tester.getRect(icon), bounds);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      state.value = (loading: false, playing: true);
      await tester.pumpAndSettle();
      expect(spinner, findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(tester.getRect(icon), bounds);
      expect(tester.binding.transientCallbackCount, 0);

      state.value = (loading: true, playing: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(spinner, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion uses a static ring and keeps the control foreground',
    (tester) async {
      final state = ValueNotifier((loading: true, playing: false));
      addTearDown(state.dispose);
      await tester.pumpWidget(_harness(state, disableAnimations: true));
      await tester.pumpAndSettle();
      final spinner = tester.widget<CircularProgressIndicator>(
        find.byKey(const ValueKey('playback-loading-indicator')),
      );
      expect(spinner.value, isNotNull);
      expect(spinner.color, Colors.tealAccent);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loading state has a label in every supported language', (
    tester,
  ) async {
    final state = ValueNotifier((loading: true, playing: false));
    addTearDown(state.dispose);
    const english = AppStrings(AppLanguage.english);
    for (final language in AppLanguage.values) {
      final strings = AppStrings(language);
      await tester.pumpWidget(
        _harness(
          state,
          disableAnimations: true,
          label: strings.playbackLoading,
        ),
      );
      await tester.pumpAndSettle();
      final progress = tester.widget<CircularProgressIndicator>(
        find.byKey(const ValueKey('playback-loading-indicator')),
      );
      expect(
        progress.semanticsLabel,
        strings.playbackLoading,
        reason: language.code,
      );
      expect(progress.semanticsLabel, isNotEmpty);
      if (language != AppLanguage.english) {
        expect(progress.semanticsLabel, isNot(english.playbackLoading));
      }
    }
    expect(tester.takeException(), isNull);
  });
}

Widget _harness(
  ValueNotifier<({bool loading, bool playing})> state, {
  bool disableAnimations = false,
  String label = 'Loading song',
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
  home: Scaffold(
    body: Center(
      child: IconTheme(
        data: const IconThemeData(color: Colors.tealAccent),
        child: ValueListenableBuilder<({bool loading, bool playing})>(
          valueListenable: state,
          builder: (context, value, _) => PlaybackControlIcon(
            isLoading: value.loading,
            isPlaying: value.playing,
            size: 48,
            playOffset: const Offset(1.5, 0),
            loadingLabel: label,
          ),
        ),
      ),
    ),
  ),
);
