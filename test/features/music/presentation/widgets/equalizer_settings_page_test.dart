import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/core/widgets/app_shared_widgets.dart';
import 'package:bstream_music/features/music/presentation/providers/equalizer_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/equalizer_preset_icon.dart';
import 'package:bstream_music/features/music/presentation/widgets/equalizer_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'header inherits surfaces and remains pinned above the controls',
    (tester) async {
      _size(tester, const Size(320, 568));
      for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
        for (final brightness in Brightness.values) {
          for (final mode in SurfaceBackgroundMode.values) {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpWidget(
              _harness(
                surfaceBackgroundMode: mode,
                platform: platform,
                brightness: brightness,
                viewPadding: const EdgeInsets.only(top: 24),
              ),
            );
            await tester.tap(find.byKey(const ValueKey('open-equalizer')));
            await tester.pumpAndSettle();
            final surface = find.byKey(
              const ValueKey('equalizer-header-surface'),
            );
            final glass = find.ancestor(
              of: surface,
              matching: find.byType(LiquidGlassSurface),
            );
            expect(glass, mode.isLiquidGlass ? findsOneWidget : findsNothing);
            if (!mode.isLiquidGlass) {
              expect(
                find.ancestor(
                  of: surface,
                  matching: find.byType(BackdropFilter),
                ),
                mode.usesBackdrop ? findsOneWidget : findsNothing,
              );
            }
            expect(
              find.byKey(const ValueKey('browsing-tab-background-surface')),
              findsOneWidget,
            );
            for (final key in ['equalizer-power-card']) {
              final card = find.byKey(ValueKey(key));
              final material = tester.widget<Material>(
                find
                    .descendant(of: card, matching: find.byType(Material))
                    .first,
              );
              expect(
                material.color,
                AppColors.cardSurfaceFor(tester.element(card)),
              );
            }
            final headerRect = tester.getRect(surface);
            expect(headerRect.top, 24);
            final overlay = tester
                .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
                  find
                      .ancestor(
                        of: find.byKey(
                          const ValueKey('equalizer-settings-page'),
                        ),
                        matching: find.byType(
                          AnnotatedRegion<SystemUiOverlayStyle>,
                        ),
                      )
                      .first,
                );
            expect(
              overlay.value.statusBarIconBrightness,
              brightness == Brightness.dark
                  ? Brightness.light
                  : Brightness.dark,
            );
            await _reveal(
              tester,
              find.byKey(const ValueKey('equalizer-band-guides')),
            );
            await tester.pump(const Duration(milliseconds: 250));
            await tester.pumpAndSettle();
            expect(tester.getRect(surface), headerRect);
            final back = find.byKey(const ValueKey('equalizer-back'));
            expect(back.hitTestable(), findsOneWidget);
            expect(
              find.descendant(
                of: find.byKey(const ValueKey('equalizer-controls')),
                matching: find.byType(LiquidGlassSurface),
              ),
              findsNothing,
            );
            await tester.tap(back);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('open-equalizer')),
              findsOneWidget,
            );
            expect(
              tester.takeException(),
              isNull,
              reason: '$platform / $brightness / $mode',
            );
          }
        }
      }
    },
  );

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
    final controlsCard = find.byKey(const ValueKey('equalizer-controls'));
    final presetCards = find.byKey(const ValueKey('equalizer-presets'));
    final resetButton = find.byKey(const ValueKey('equalizer-reset'));
    expect(
      find.ancestor(
        of: controlsCard,
        matching: find.byType(AppCardGradientBorder),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: presetCards, matching: resetButton),
      findsNothing,
    );
    expect(
      tester.getRect(resetButton).top,
      greaterThan(tester.getRect(controlsCard).bottom),
    );
    expect(tester.getRect(controlsCard).left, 0);
    expect(tester.getRect(controlsCard).right, 390);
    expect(find.byKey(const ValueKey('equalizer-chart-card')), findsNothing);
    expect(find.descendant(of: powerCard, matching: enabled), findsOneWidget);
    expect(
      find.descendant(of: powerCard, matching: find.byType(Slider)),
      findsNothing,
    );
    expect(
      find.descendant(of: controlsCard, matching: find.byType(Slider)),
      findsNWidgets(10),
    );
    expect(SliderTheme.of(tester.element(bass)).trackHeight, 4);
    expect(
      tester.getTopLeft(presetCards).dy,
      greaterThan(tester.getBottomLeft(powerCard).dy),
    );
    expect(
      tester.getTopLeft(controlsCard).dy,
      greaterThan(tester.getBottomLeft(presetCards).dy),
    );
    expect(
      find.descendant(of: presetCards, matching: find.byType(InkWell)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: presetCards, matching: find.byType(Slider)),
      findsNothing,
    );
    expect(current().enabled, isFalse);
    expect(find.text('Disabled'), findsOneWidget);
    expect(tester.widget<Slider>(bass).onChanged, isNull);

    await _choose(tester, EqualizerPreset.rock);
    expect(current().enabled, isTrue);
    expect(find.text('Enabled'), findsOneWidget);
    expect(current().gainsDb, EqualizerPreset.rock.gainsDb);

    // Turning it off keeps the curve. Reset also preserves that disabled state.
    final adjusted = current().gainsDb;
    await _reveal(tester, enabled);
    await tester.tap(enabled);
    await tester.pumpAndSettle();
    expect(current().enabled, isFalse);
    expect(current().gainsDb, adjusted);
    final reset = find.byKey(const ValueKey('equalizer-reset'));
    await _reveal(tester, reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(current().enabled, isFalse);
    expect(current().isFlat, isTrue);
    // A disabled reset remains independent from preset selection.
    await tester.tap(reset, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('glass-popup-menu-surface')),
      findsNothing,
    );
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
    await _reveal(tester, bass);
    await tester.drag(bass, const Offset(0, -40));
    await tester.pumpAndSettle();
    expect(current().gainsDb.first, greaterThan(0));
    expect(current().gainsDb.skip(1), everyElement(0));
    expect(current().preset, EqualizerPreset.custom);
    expect(find.text('Custom'), findsOneWidget);

    // Return the thumb to the midpoint before checking the other direction,
    // so the gesture measures dragging rather than a jump to the tapped point.
    final reset = find.byKey(const ValueKey('equalizer-reset'));
    await _reveal(tester, reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(current().enabled, isTrue);
    expect(current().isFlat, isTrue);
    await _reveal(tester, bass);
    await tester.drag(bass, const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(current().gainsDb.first, lessThan(0));
    expect(current().gainsDb.skip(1), everyElement(0));
    expect(current().preset, EqualizerPreset.custom);
    await _dragFaderToEnd(tester, bass, current().gainsDb.first, up: false);
    expect(current().gainsDb.first, equalizerMinGainDb);
    await _dragFaderToEnd(tester, bass, current().gainsDb.first, up: true);
    expect(current().gainsDb.first, equalizerMaxGainDb);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'preset picker updates its label and the custom card restores saved bands',
    (tester) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(_harness());
      await tester.tap(find.byKey(const ValueKey('open-equalizer')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EqualizerSettingsPage)),
      );
      EqualizerSettings current() =>
          container.read(settingsControllerProvider).requireValue.equalizer;
      final customCard = find.byKey(const ValueKey('equalizer-preset-custom'));
      final presetCard = find.byKey(const ValueKey('equalizer-preset-picker'));
      Finder presetLabel(String name) =>
          find.descendant(of: presetCard, matching: find.text(name));
      expect(tester.getSize(customCard), tester.getSize(presetCard));
      expect(presetLabel('Flat'), findsOneWidget);
      expect(_presetSelected(tester, presetCard), isTrue);
      for (final card in [customCard, presetCard]) {
        expect(
          tester
              .widget<AppCardGradientBorder>(
                find.descendant(
                  of: card,
                  matching: find.byType(AppCardGradientBorder),
                ),
              )
              .solidInLiquidGlass,
          isTrue,
        );
      }
      await tester.tap(presetCard);
      await tester.pumpAndSettle();
      final options = find.byKey(const ValueKey('glass-popup-menu-surface'));
      expect(options, findsOneWidget);
      for (final preset in EqualizerPreset.values) {
        final option = find.descendant(
          of: options,
          matching: _presetChoice(preset),
        );
        expect(
          option,
          preset == EqualizerPreset.custom ? findsNothing : findsOneWidget,
        );
        if (preset == EqualizerPreset.custom) continue;
        final icon = tester.widget<EqualizerPresetIcon>(
          find.descendant(
            of: option,
            matching: find.byType(EqualizerPresetIcon),
          ),
        );
        expect(icon.preset, preset);
        expect(
          find.descendant(
            of: option,
            matching: find.byIcon(Icons.check_rounded),
          ),
          preset == EqualizerPreset.flat ? findsOneWidget : findsNothing,
        );
      }
      await _tapPreset(tester, EqualizerPreset.rock);
      expect(options, findsNothing);
      expect(presetLabel('Rock'), findsOneWidget);
      expect(_presetSelected(tester, presetCard), isTrue);
      final decoration =
          tester
                  .widget<AnimatedContainer>(
                    find.descendant(
                      of: presetCard,
                      matching: find.byType(AnimatedContainer),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      expect(
        decoration.gradient,
        AppColors.selectedCardGradientFor(tester.element(presetCard)),
      );
      final bass = find.byKey(const ValueKey('equalizer-band-0'));
      await _dragFaderToEnd(tester, bass, current().gainsDb.first, up: false);
      final custom = List<double>.of(current().gainsDb);
      expect(_presetSelected(tester, customCard), isTrue);
      expect(presetLabel('Rock'), findsOneWidget);
      await _choose(tester, EqualizerPreset.bassBoost);
      expect(current().gainsDb, EqualizerPreset.bassBoost.gainsDb);
      await _choose(tester, EqualizerPreset.custom);
      expect(current().gainsDb, custom);
      expect(presetLabel('Bass boost'), findsOneWidget);
      expect(_presetSelected(tester, presetCard), isFalse);
      expect(tester.widget<Slider>(bass).value, custom.first);
      expect(_visualRect(tester, bass).height, greaterThanOrEqualTo(280));
      await tester.tap(find.byKey(const ValueKey('equalizer-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-equalizer')));
      await tester.pumpAndSettle();
      expect(current().gainsDb, custom);
      expect(_presetSelected(tester, customCard), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop puts preset cards below power and above taller full-width bands',
    (tester) async {
      _size(tester, const Size(1100, 850));
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          _harness(textScale: scale, platform: TargetPlatform.windows),
        );
        await tester.tap(find.byKey(const ValueKey('open-equalizer')));
        await tester.pumpAndSettle();
        final power = tester.getRect(
          find.byKey(const ValueKey('equalizer-power-card')),
        );
        final presets = tester.getRect(
          find.byKey(const ValueKey('equalizer-presets')),
        );
        final controls = tester.getRect(
          find.byKey(const ValueKey('equalizer-controls')),
        );
        expect(presets.top, greaterThan(power.bottom));
        expect(presets.left, 0);
        expect(presets.right, 1100);
        expect(controls.top, greaterThan(power.bottom));
        expect(controls.top, greaterThan(presets.bottom));
        expect(controls.left, 0);
        expect(controls.right, 1100);
        if (scale == 1) expect(controls.height, greaterThan(400));
        expect(
          tester.getRect(find.byKey(const ValueKey('equalizer-reset'))).top,
          greaterThan(controls.bottom),
        );
        expect(
          find.byKey(const ValueKey('equalizer-chart-card')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'integrated guides follow presets and reset without redundant repaint',
    (tester) async {
      _size(tester, const Size(390, 844));
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _harness(initial: const EqualizerSettings(enabled: true)),
        );
        await tester.tap(find.byKey(const ValueKey('open-equalizer')));
        await tester.pumpAndSettle();
        final chart = find.byKey(const ValueKey('equalizer-band-guides'));
        expect(chart, findsOneWidget);
        await _reveal(tester, chart);
        await tester.pumpAndSettle();
        final flatPainter = _guidesPainter(tester);

        await _choose(tester, EqualizerPreset.rock);
        await _reveal(tester, chart);
        await tester.pumpAndSettle();
        final rockPainter = _guidesPainter(tester);
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
        expect(_guidesPainter(tester).shouldRepaint(rockPainter), isFalse);

        final reset = find.byKey(const ValueKey('equalizer-reset'));
        await _reveal(tester, reset);
        await tester.tap(reset);
        await tester.pumpAndSettle();
        await _reveal(tester, chart);
        await tester.pumpAndSettle();
        expect(_guidesPainter(tester).shouldRepaint(rockPainter), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'compact layout keeps ten vertical bands and integrated guides with accessible reset',
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
      expect(find.byType(Slider), findsNWidgets(10));
      final bands = [
        for (var band = 0; band < equalizerBandFrequencies.length; band++)
          _visualRect(tester, find.byKey(ValueKey('equalizer-band-$band'))),
      ];
      for (var band = 0; band < bands.length; band++) {
        final rect = bands[band];
        expect(rect.height, greaterThan(rect.width));
        expect(rect.width, greaterThanOrEqualTo(24));
        expect(rect.height, greaterThanOrEqualTo(100));
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
      await _reveal(tester, reset);
      await tester.pumpAndSettle();
      final viewport = _visualRect(tester, pageScroll);
      expect(bands.first.left, greaterThanOrEqualTo(viewport.left));
      expect(bands.last.right, lessThanOrEqualTo(viewport.right + .1));
      final resetRect = _visualRect(tester, reset);
      expect(resetRect.top, greaterThanOrEqualTo(viewport.top));
      expect(resetRect.bottom, lessThanOrEqualTo(viewport.bottom + 0.1));
      expect(reset.hitTestable(), findsOneWidget);
      final chart = find.byKey(const ValueKey('equalizer-band-guides'));
      await _reveal(tester, chart);
      await tester.pumpAndSettle();
      final chartRect = _visualRect(tester, chart);
      expect(chartRect.width, lessThanOrEqualTo(viewport.width));
      expect(chartRect.height, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(360, 740)]) {
    testWidgets(
      'phone ${size.width}x${size.height} shows ten taller bands and separate presets without scrolling',
      (tester) async {
        _size(tester, size);
        for (final language in AppLanguage.values) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            _harness(
              language: language,
              viewPadding: const EdgeInsets.only(top: 24, bottom: 34),
              initial: EqualizerSettings(
                enabled: true,
                gainsDb: EqualizerPreset.smallSpeakers.gainsDb,
              ),
            ),
          );
          await tester.tap(find.byKey(const ValueKey('open-equalizer')));
          await tester.pumpAndSettle();

          final strings = AppStrings(language);
          expect(
            find.text(strings.equalizerPresetName(EqualizerPreset.custom)),
            findsOneWidget,
          );
          expect(
            find.text(
              strings.equalizerPresetName(EqualizerPreset.smallSpeakers),
            ),
            findsOneWidget,
          );
          final scroll = find
              .descendant(
                of: find.byKey(const ValueKey('equalizer-settings-scroll')),
                matching: find.byType(Scrollable),
              )
              .first;
          final state = tester.state<ScrollableState>(scroll);
          final viewport = _visualRect(tester, scroll);
          final header = tester.getRect(
            find.byKey(const ValueKey('equalizer-header-surface')),
          );
          expect(state.position.pixels, 0);
          expect(
            state.position.maxScrollExtent,
            closeTo(0, .1),
            reason: language.code,
          );
          final bands = <Rect>[];
          for (var band = 0; band < equalizerBandFrequencies.length; band++) {
            final slider = find.byKey(ValueKey('equalizer-band-$band'));
            final rect = _visualRect(tester, slider);
            bands.add(rect);
            expect(rect.width, greaterThanOrEqualTo(24));
            expect(rect.height, greaterThanOrEqualTo(100));
            expect(rect.left, greaterThanOrEqualTo(viewport.left));
            expect(rect.right, lessThanOrEqualTo(viewport.right + .1));
            expect(rect.top, greaterThanOrEqualTo(header.bottom));
            expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + .1));
            expect(
              slider.hitTestable(),
              findsOneWidget,
              reason: '${language.code} / band $band',
            );
          }
          for (var band = 0; band < bands.length; band++) {
            expect(bands[band].center.dy, closeTo(bands.first.center.dy, 1));
            if (band > 0) {
              expect(
                bands[band].left,
                greaterThanOrEqualTo(bands[band - 1].right - .1),
              );
            }
          }
          for (final key in ['equalizer-reset', 'equalizer-controls']) {
            final rect = tester.getRect(find.byKey(ValueKey(key)));
            expect(rect.top, greaterThanOrEqualTo(header.bottom));
            expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + .1));
          }
          expect(
            find.byKey(const ValueKey('equalizer-reset')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull, reason: language.code);
        }
      },
    );
  }

  testWidgets('fractional gains remain readable in the narrow ten-band row', (
    tester,
  ) async {
    _size(tester, const Size(320, 568));
    final gains = List<double>.generate(10, (i) => i.isEven ? 11.5 : -11.5);
    await tester.pumpWidget(
      _harness(initial: EqualizerSettings(enabled: true, gainsDb: gains)),
    );
    await tester.tap(find.byKey(const ValueKey('open-equalizer')));
    await tester.pumpAndSettle();
    for (var band = 0; band < gains.length; band++) {
      final slider = find.byKey(ValueKey('equalizer-band-$band'));
      final gain = find.byKey(ValueKey('equalizer-band-$band-gain'));
      final sliderRect = _visualRect(tester, slider);
      final gainRect = _visualRect(tester, gain);
      final label = tester.widget<Text>(gain);
      expect(label.data, band.isEven ? '+11.5' : '-11.5');
      expect(
        tester.renderObject<RenderParagraph>(gain).didExceedMaxLines,
        isFalse,
      );
      expect(gainRect.left, greaterThanOrEqualTo(sliderRect.left - .1));
      expect(gainRect.right, lessThanOrEqualTo(sliderRect.right + .1));
      expect(tester.widget<Slider>(slider).value, gains[band]);
      expect(slider.hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

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
        await _reveal(tester, slider);
        await tester.pumpAndSettle();
        expect(tester.widget<Slider>(slider).onChanged, isNotNull);
        final rect = _visualRect(tester, slider);
        expect(rect.height, greaterThan(rect.width));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(slider.hitTestable(), findsOneWidget);
      }
      await _reveal(tester, find.byKey(const ValueKey('equalizer-reset')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('equalizer-reset')).hitTestable(),
        findsOneWidget,
      );
      final chart = find.byKey(const ValueKey('equalizer-band-guides'));
      expect(chart, findsOneWidget);
      await _reveal(tester, chart);
      await tester.pumpAndSettle();
      expect(
        _visualRect(tester, chart).width,
        closeTo(
          _visualRect(
                tester,
                find.byKey(const ValueKey('equalizer-band-0')),
              ).width *
              10,
          .1,
        ),
      );
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
      await tester.tap(find.byKey(const ValueKey('equalizer-preset-picker')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('glass-popup-menu-surface')),
        findsNothing,
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

CustomPainter _guidesPainter(WidgetTester tester) {
  final chart = find.byKey(const ValueKey('equalizer-band-guides'));
  final widget = tester.widget(chart);
  if (widget is CustomPaint) return widget.painter!;
  return tester
      .widget<CustomPaint>(
        find.descendant(of: chart, matching: find.byType(CustomPaint)).first,
      )
      .painter!;
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

Future<void> _dragFaderToEnd(
  WidgetTester tester,
  Finder slider,
  double currentGain, {
  required bool up,
}) async {
  // Short faders need the pointer on the actual thumb. Starting in the center
  // when the thumb is near an endpoint can begin a tap or a parent scroll.
  final rect = _visualRect(tester, slider);
  final fraction =
      (currentGain - equalizerMinGainDb) /
      (equalizerMaxGainDb - equalizerMinGainDb);
  final start = Offset(
    rect.center.dx,
    // An endpoint is on the inner RenderSlider's exact hit-test boundary.
    // Stay inside the cap by 1 dp so the inverse rotation cannot round its
    // local coordinate to a tiny negative number and miss the pointer down.
    (rect.bottom - 12 - fraction * (rect.height - 24))
        .clamp(rect.top + 13, rect.bottom - 13)
        .toDouble(),
  );
  final end = Offset(start.dx, up ? rect.top - 32 : rect.bottom + 32);
  final gesture = await tester.startGesture(start);
  await tester.pump();
  for (var step = 1; step <= 4; step++) {
    await gesture.moveTo(Offset.lerp(start, end, step / 4)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: .3);
  await tester.pumpAndSettle();
}

Finder _presetChoice(EqualizerPreset preset) =>
    find.byKey(ValueKey('equalizer-preset-${preset.name}'));

Future<void> _tapPreset(WidgetTester tester, EqualizerPreset preset) async {
  final choice = _presetChoice(preset);
  await _reveal(tester, choice);
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, EqualizerPreset preset) async {
  if (preset != EqualizerPreset.custom) {
    final picker = find.byKey(const ValueKey('equalizer-preset-picker'));
    await _reveal(tester, picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
  }
  await _tapPreset(tester, preset);
}

bool? _presetSelected(WidgetTester tester, Finder card) => tester
    .widget<Semantics>(
      find.descendant(of: card, matching: find.byType(Semantics)).first,
    )
    .properties
    .selected;

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
  SurfaceBackgroundMode surfaceBackgroundMode = SurfaceBackgroundMode.accent,
  TargetPlatform platform = TargetPlatform.android,
  Brightness brightness = Brightness.light,
  EdgeInsets viewPadding = EdgeInsets.zero,
  AppLanguage language = AppLanguage.english,
}) => ProviderScope(
  overrides: [
    settingsControllerProvider.overrideWith(() => _Settings(initial)),
    appStringsProvider.overrideWithValue(AppStrings(language)),
    equalizerRuntimeProvider.overrideWith(_SupportedRuntime.new),
    equalizerAvailableProvider.overrideWithValue(available),
  ],
  child: MaterialApp(
    theme: ThemeData(
      platform: platform,
      brightness: brightness,
      extensions: [AppSurfaceTheme(backgroundMode: surfaceBackgroundMode)],
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        padding: viewPadding,
        viewPadding: viewPadding,
      ),
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
    final current = state.requireValue;
    _apply((
      equalizer: value.normalized,
      profiles: current.equalizerProfiles.updating(
        current.equalizer,
        value.normalized,
      ),
    ));
  }

  @override
  Future<void> setEqualizerBand(int index, double gain) async {
    final current = state.requireValue;
    _apply(current.equalizerProfiles.withBand(current.equalizer, index, gain));
  }

  @override
  Future<void> selectEqualizerPreset(EqualizerPreset preset) async {
    final current = state.requireValue;
    _apply(current.equalizerProfiles.choose(current.equalizer, preset));
  }

  void _apply(EqualizerProfileChange change) {
    state = AsyncData(
      state.requireValue.copyWith(
        equalizer: change.equalizer,
        equalizerProfiles: change.profiles,
      ),
    );
  }
}
