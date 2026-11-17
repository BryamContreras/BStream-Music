import 'package:bstream_music/features/music/presentation/providers/equalizer_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/equalizer_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shared route applies presets and reset preserves disabled state', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(_harness());
    await tester.tap(find.byKey(const ValueKey('open-equalizer')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('equalizer-settings-page')),
      findsOneWidget,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EqualizerSettingsPage)),
    );
    EqualizerSettings current() =>
        container.read(settingsControllerProvider).requireValue.equalizer;
    final enabled = find.byKey(const ValueKey('equalizer-enabled'));
    final bass = find.byKey(const ValueKey('equalizer-band-0'));
    final powerCard = find.byKey(const ValueKey('equalizer-power-card'));
    final controlsCard = find.byKey(const ValueKey('equalizer-controls-card'));
    final chartCard = find.byKey(const ValueKey('equalizer-chart-card'));
    expect(find.descendant(of: powerCard, matching: enabled), findsOneWidget);
    expect(
      find.descendant(of: powerCard, matching: find.byType(Slider)),
      findsNothing,
    );
    expect(
      find.descendant(of: controlsCard, matching: find.byType(Slider)),
      findsNWidgets(5),
    );
    expect(
      tester.getTopLeft(controlsCard).dy,
      greaterThan(tester.getBottomLeft(powerCard).dy),
    );
    expect(
      tester.getTopLeft(chartCard).dy,
      greaterThan(tester.getBottomLeft(controlsCard).dy),
    );
    expect(current().enabled, isFalse);
    expect(tester.widget<Slider>(bass).onChanged, isNull);

    await _choose(tester, EqualizerPreset.rock);
    expect(current().enabled, isTrue);
    expect(current().gainsDb, EqualizerPreset.rock.gainsDb);

    // Turning it off keeps the curve. Reset also preserves that disabled state.
    final adjusted = current().gainsDb;
    await tester.ensureVisible(enabled);
    await tester.tap(enabled);
    await tester.pumpAndSettle();
    expect(current().enabled, isFalse);
    expect(current().gainsDb, adjusted);
    final reset = find.byKey(const ValueKey('equalizer-reset'));
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(current().enabled, isFalse);
    expect(current().isFlat, isTrue);
    await tester.tap(find.byKey(const ValueKey('equalizer-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-equalizer')), findsOneWidget);
    expect(find.byType(EqualizerSettingsPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical bands increase upwards and decrease downwards', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    await tester.pumpWidget(
      _harness(initial: const EqualizerSettings(enabled: true)),
    );
    await tester.tap(find.byKey(const ValueKey('open-equalizer')));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EqualizerSettingsPage)),
    );
    EqualizerSettings current() =>
        container.read(settingsControllerProvider).requireValue.equalizer;
    final bass = find.byKey(const ValueKey('equalizer-band-0'));
    await tester.ensureVisible(bass);
    await tester.drag(bass, const Offset(0, -40));
    await tester.pumpAndSettle();
    expect(current().gainsDb.first, greaterThan(0));
    expect(current().gainsDb.skip(1), everyElement(0));
    expect(current().preset, EqualizerPreset.custom);
    expect(find.text('Custom'), findsOneWidget);

    // Return the thumb to the midpoint before checking the other direction,
    // so the gesture measures dragging rather than a jump to the tapped point.
    final reset = find.byKey(const ValueKey('equalizer-reset'));
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(current().enabled, isTrue);
    expect(current().isFlat, isTrue);
    await tester.ensureVisible(bass);
    await tester.drag(bass, const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(current().gainsDb.first, lessThan(0));
    expect(current().gainsDb.skip(1), everyElement(0));
    expect(current().preset, EqualizerPreset.custom);
    expect(tester.takeException(), isNull);
  });

  testWidgets('curve chart follows presets and reset without redundant repaint', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _harness(initial: const EqualizerSettings(enabled: true)),
      );
      await tester.tap(find.byKey(const ValueKey('open-equalizer')));
      await tester.pumpAndSettle();
      final chart = find.byKey(const ValueKey('equalizer-curve-chart'));
      expect(chart, findsOneWidget);
      await tester.ensureVisible(chart);
      await tester.pumpAndSettle();
      _expectCurveSemantics(tester, const EqualizerSettings().gainsDb);
      final flatPainter = _curvePainter(tester);

      await _choose(tester, EqualizerPreset.rock);
      await tester.ensureVisible(chart);
      await tester.pumpAndSettle();
      _expectCurveSemantics(tester, EqualizerPreset.rock.gainsDb);
      final rockPainter = _curvePainter(tester);
      expect(rockPainter.shouldRepaint(flatPainter), isTrue);

      // Rebuild with an equal curve to verify that ordinary state notifications
      // do not request another paint of the same graph.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EqualizerSettingsPage)),
      );
      final equalizer = container
          .read(settingsControllerProvider)
          .requireValue
          .equalizer;
      await container
          .read(settingsControllerProvider.notifier)
          .setEqualizer(equalizer.copyWith());
      await tester.pumpAndSettle();
      expect(_curvePainter(tester).shouldRepaint(rockPainter), isFalse);

      final reset = find.byKey(const ValueKey('equalizer-reset'));
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      await tester.ensureVisible(chart);
      await tester.pumpAndSettle();
      _expectCurveSemantics(tester, const EqualizerSettings().gainsDb);
      expect(_curvePainter(tester).shouldRepaint(rockPainter), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'compact layout keeps five vertical bands and chart with accessible reset',
    (tester) async {
      _size(tester, const Size(320, 568));
      await tester.pumpWidget(
        _harness(
          initial: EqualizerSettings(
            enabled: true,
            gainsDb: EqualizerPreset.rock.gainsDb,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-equalizer')));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNWidgets(5));
      final bands = [
        for (var band = 0; band < equalizerBandFrequencies.length; band++)
          _visualRect(tester, find.byKey(ValueKey('equalizer-band-$band'))),
      ];
      for (var band = 0; band < bands.length; band++) {
        final rect = bands[band];
        expect(rect.height, greaterThan(rect.width));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.center.dy, closeTo(bands.first.center.dy, 1));
        if (band > 0) {
          expect(rect.left, greaterThanOrEqualTo(bands[band - 1].right - 0.1));
        }
      }
      final pageScroll = find
          .descendant(
            of: find.byKey(const ValueKey('equalizer-settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      final scrollState = tester.state<ScrollableState>(pageScroll);
      expect(scrollState.position.axis, Axis.vertical);
      expect(scrollState.position.pixels, 0);
      final reset = find.byKey(const ValueKey('equalizer-reset'));
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      final viewport = _visualRect(tester, pageScroll);
      final resetRect = _visualRect(tester, reset);
      expect(resetRect.top, greaterThanOrEqualTo(viewport.top));
      expect(resetRect.bottom, lessThanOrEqualTo(viewport.bottom + 0.1));
      expect(reset.hitTestable(), findsOneWidget);
      final chart = find.byKey(const ValueKey('equalizer-curve-chart'));
      await tester.ensureVisible(chart);
      await tester.pumpAndSettle();
      final chartRect = _visualRect(tester, chart);
      expect(chartRect.width, lessThanOrEqualTo(viewport.width));
      expect(chartRect.height, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact large text can reach all vertical bands with usable touch targets',
    (tester) async {
      _size(tester, const Size(320, 568));
      await tester.pumpWidget(_harness(textScale: 2));
      await tester.tap(find.byKey(const ValueKey('open-equalizer')));
      await tester.pumpAndSettle();
      await _choose(tester, EqualizerPreset.lateNight);
      for (var band = 0; band < equalizerBandFrequencies.length; band++) {
        final slider = find.byKey(ValueKey('equalizer-band-$band'));
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        expect(tester.widget<Slider>(slider).onChanged, isNotNull);
        final rect = _visualRect(tester, slider);
        expect(rect.height, greaterThan(rect.width));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(slider.hitTestable(), findsOneWidget);
      }
      await tester.ensureVisible(find.byKey(const ValueKey('equalizer-reset')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('equalizer-reset')).hitTestable(),
        findsOneWidget,
      );
      final chart = find.byKey(const ValueKey('equalizer-curve-chart'));
      expect(chart, findsOneWidget);
      await tester.ensureVisible(chart);
      await tester.pumpAndSettle();
      expect(_visualRect(tester, chart).width, lessThanOrEqualTo(320));
      expect(_visualRect(tester, chart).height, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'casting leaves saved tuning intact and disables local controls',
    (tester) async {
      _size(tester, const Size(390, 844));
      final initial = EqualizerSettings(
        enabled: true,
        gainsDb: EqualizerPreset.acoustic.gainsDb,
      );
      await tester.pumpWidget(_harness(available: false, initial: initial));
      await tester.tap(find.byKey(const ValueKey('open-equalizer')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          const AppStrings(AppLanguage.english).equalizerCastUnavailable,
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('equalizer-enabled')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('equalizer-band-0')))
            .onChanged,
        isNull,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EqualizerSettingsPage)),
      );
      expect(
        container.read(settingsControllerProvider).requireValue.equalizer,
        initial,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

CustomPainter _curvePainter(WidgetTester tester) {
  final chart = find.byKey(const ValueKey('equalizer-curve-chart'));
  final widget = tester.widget(chart);
  if (widget is CustomPaint) return widget.painter!;
  return tester
      .widget<CustomPaint>(
        find.descendant(of: chart, matching: find.byType(CustomPaint)).first,
      )
      .painter!;
}

void _expectCurveSemantics(WidgetTester tester, List<double> gains) {
  final label = tester
      .getSemantics(find.byKey(const ValueKey('equalizer-curve-chart')))
      .label;
  const strings = AppStrings(AppLanguage.english);
  for (var band = 0; band < gains.length; band++) {
    final gain = gains[band];
    final digits = gain == gain.roundToDouble() ? 0 : 1;
    final number = RegExp.escape(gain.toStringAsFixed(digits));
    final sign = gain > 0 ? r'\+?' : '';
    expect(
      label,
      matches(
        '${RegExp.escape(strings.equalizerBandName(band))}'
        r'\s*[:=]?\s*'
        '$sign$number'
        r'\s*dB',
      ),
      reason: 'the curve must describe the current gain of band $band',
    );
  }
}

/// Slider keeps its horizontal layout size inside RotatedBox. Measure its
/// transformed bounds to test the vertical control and its actual touch width.
Rect _visualRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(Offset(box.size.width, box.size.height)),
  );
}

Future<void> _choose(WidgetTester tester, EqualizerPreset preset) async {
  final selector = find.byKey(const ValueKey('equalizer-presets'));
  await tester.ensureVisible(selector);
  await tester.tap(selector);
  await tester.pumpAndSettle();
  final choice = find.byKey(ValueKey('equalizer-preset-${preset.name}'));
  await tester.ensureVisible(choice);
  await tester.pumpAndSettle();
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _harness({
  double textScale = 1,
  bool available = true,
  EqualizerSettings initial = const EqualizerSettings(),
}) => ProviderScope(
  overrides: [
    settingsControllerProvider.overrideWith(() => _Settings(initial)),
    appStringsProvider.overrideWithValue(const AppStrings(AppLanguage.english)),
    equalizerRuntimeProvider.overrideWith(_SupportedRuntime.new),
    equalizerAvailableProvider.overrideWithValue(available),
  ],
  child: MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: const ValueKey('open-equalizer'),
          onPressed: () => showEqualizerSettings(context),
          child: const Text('Open'),
        ),
      ),
    ),
  ),
);

class _SupportedRuntime extends EqualizerRuntimeController {
  @override
  EqualizerRuntimeState build() => const EqualizerRuntimeState(supported: true);
}

class _Settings extends SettingsController {
  _Settings(this.initial);

  final EqualizerSettings initial;

  @override
  Future<SettingsState> build() async => SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.english,
    equalizer: initial,
  );

  @override
  Future<void> setEqualizer(EqualizerSettings value) async {
    state = AsyncData(state.requireValue.copyWith(equalizer: value));
  }
}
