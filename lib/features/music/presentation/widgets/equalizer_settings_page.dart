import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/app_menu_bottom_sheet.dart';
import '../../../../core/widgets/app_shared_widgets.dart';
import 'equalizer_curve_chart.dart';
import '../providers/equalizer_providers.dart';
import '../providers/music_providers.dart';

bool supportsEqualizerSettings(BuildContext context) =>
    switch (Theme.of(context).platform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => false,
    };

/// Both settings and the player open the same controls and live configuration.
Future<void> showEqualizerSettings(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/equalizer'),
        builder: (_) => const EqualizerSettingsPage(),
      ),
    );

class EqualizerSettingsPage extends ConsumerWidget {
  const EqualizerSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final settings = ref.watch(settingsControllerProvider);
    final runtime = ref.watch(equalizerRuntimeProvider);
    final available = ref.watch(equalizerAvailableProvider);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      key: const ValueKey('equalizer-settings-page'),
      appBar: AppBar(
        toolbarHeight: math.max(
          kToolbarHeight,
          MediaQuery.textScalerOf(context).scale(22) + 20,
        ),
        leading: BackButton(key: const ValueKey('equalizer-back')),
        title: Text(
          strings.equalizer,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        top: false,
        child: settings.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(child: Text(strings.equalizerError)),
          data: (state) {
            final equalizer = state.equalizer.normalized;
            final canAdjust = available && equalizer.enabled;
            void update(EqualizerSettings value) =>
                unawaited(_save(context, ref, value));

            return SingleChildScrollView(
              key: const ValueKey('equalizer-settings-scroll'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _EqualizerSurface(
                        key: const ValueKey('equalizer-power-card'),
                        highlighted: available && equalizer.enabled,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SwitchListTile.adaptive(
                              key: const ValueKey('equalizer-enabled'),
                              dense: true,
                              secondary: Icon(
                                Icons.equalizer_rounded,
                                color: available && equalizer.enabled
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                              contentPadding: const EdgeInsets.fromLTRB(
                                12,
                                4,
                                8,
                                4,
                              ),
                              title: Text(
                                strings.equalizerEnabled,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              value: equalizer.enabled,
                              onChanged: available
                                  ? (enabled) => update(
                                      equalizer.copyWith(enabled: enabled),
                                    )
                                  : null,
                            ),
                            if (!available || runtime.error != null) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  8,
                                ),
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    !available
                                        ? runtime.supported
                                              ? strings.equalizerCastUnavailable
                                              : strings.equalizerUnavailable
                                        : strings.equalizerError,
                                    key: const ValueKey(
                                      'equalizer-status-message',
                                    ),
                                    style: TextStyle(
                                      color: runtime.error != null && available
                                          ? colors.error
                                          : colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            SizedBox(
                              height: 3,
                              child: runtime.applying
                                  ? const LinearProgressIndicator(minHeight: 2)
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _EqualizerSurface(
                        key: const ValueKey('equalizer-controls-card'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ListTile(
                              key: const ValueKey('equalizer-presets'),
                              enabled: available,
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              leading: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.primary.withValues(alpha: .08),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(9),
                                  child: Icon(
                                    Icons.tune_rounded,
                                    size: 20,
                                    color: colors.primary,
                                  ),
                                ),
                              ),
                              title: Text(strings.equalizerPresets),
                              subtitle: Text(
                                strings.equalizerPresetName(equalizer.preset),
                                key: const ValueKey('equalizer-current-preset'),
                                style: TextStyle(
                                  color: canAdjust
                                      ? colors.primary
                                      : colors.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              trailing: const Icon(Icons.expand_more_rounded),
                              onTap: available
                                  ? () => _choosePreset(context, ref)
                                  : null,
                            ),
                            const Divider(height: 1, indent: 12, endIndent: 12),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _EqualizerBands(
                                    settings: equalizer,
                                    strings: strings,
                                    onChanged: canAdjust
                                        ? (index, gain) => update(
                                            ref
                                                .read(
                                                  settingsControllerProvider,
                                                )
                                                .requireValue
                                                .equalizer
                                                .withBand(index, gain),
                                          )
                                        : null,
                                  ),
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    key: const ValueKey('equalizer-reset'),
                                    style: OutlinedButton.styleFrom(
                                      minimumSize: const Size(0, 40),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      side: BorderSide(
                                        color: colors.outlineVariant.withValues(
                                          alpha: .4,
                                        ),
                                      ),
                                    ),
                                    onPressed: available && !equalizer.isFlat
                                        ? () => update(
                                            equalizer.copyWith(
                                              gainsDb:
                                                  EqualizerPreset.flat.gainsDb,
                                            ),
                                          )
                                        : null,
                                    icon: const Icon(Icons.restart_alt_rounded),
                                    label: Text(
                                      strings.equalizerReset,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _EqualizerSurface(
                        key: const ValueKey('equalizer-chart-card'),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  EqualizerCurveIcon(
                                    size: 20,
                                    color: colors.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      strings.equalizerCurve,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                strings.equalizerCurveHint,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                              const SizedBox(height: 12),
                              EqualizerCurveChart(
                                settings: equalizer,
                                active: available && equalizer.enabled,
                                bandLabels: [
                                  for (
                                    var index = 0;
                                    index < equalizerBandFrequencies.length;
                                    index++
                                  )
                                    strings.equalizerBandName(index),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _choosePreset(BuildContext context, WidgetRef ref) async {
    final strings = ref.read(appStringsProvider);
    final current = ref.read(settingsControllerProvider).requireValue.equalizer;
    final selected = await showAppMenuBottomSheet<EqualizerPreset>(
      context: context,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const ValueKey('equalizer-preset-options'),
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  strings.equalizerPresets,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 12),
              for (final preset in EqualizerPreset.values)
                if (preset != EqualizerPreset.custom)
                  ListTile(
                    key: ValueKey('equalizer-preset-${preset.name}'),
                    title: Text(strings.equalizerPresetName(preset)),
                    selected: current.preset == preset,
                    trailing: current.preset == preset
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.of(context).pop(preset),
                  ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !context.mounted) return;
    // Read again after the chooser closes so changes from another entry point
    // cannot be overwritten by the state that opened it.
    final latest = ref.read(settingsControllerProvider).requireValue.equalizer;
    await _save(
      context,
      ref,
      latest.copyWith(enabled: true, gainsDb: selected.gainsDb),
    );
  }

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    EqualizerSettings settings,
  ) async {
    try {
      await ref
          .read(settingsControllerProvider.notifier)
          .setEqualizer(settings);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(ref.read(appStringsProvider).equalizerError)),
      );
    }
  }
}

class _EqualizerBands extends StatelessWidget {
  const _EqualizerBands({
    required this.settings,
    required this.strings,
    required this.onChanged,
  });

  final EqualizerSettings settings;
  final AppStrings strings;
  final void Function(int index, double gain)? onChanged;

  @override
  Widget build(BuildContext context) => SliderTheme(
    data: SliderTheme.of(context).copyWith(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
      showValueIndicator: ShowValueIndicator.never,
      activeTickMarkColor: Colors.transparent,
      inactiveTickMarkColor: Colors.transparent,
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // Large text can scroll horizontally instead of shrinking labels or
        // making adjacent controls share the same touch target.
        final gainStyle = Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700);
        final gainMeasure = TextPainter(
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        );
        var widestGain = 0.0;
        try {
          // Measure both signs with the actual font. Wider fonts and larger
          // accessibility sizes scroll rather than wrapping a numeric value.
          for (final numeric in const ['+11.5', '-11.5']) {
            gainMeasure.text = TextSpan(text: numeric, style: gainStyle);
            gainMeasure.layout();
            widestGain = math.max(widestGain, gainMeasure.width);
          }
        } finally {
          gainMeasure.dispose();
        }
        final minBandWidth = math.max(
          math.max(48.0, widestGain + 16),
          MediaQuery.textScalerOf(context).scale(12) * 4,
        );
        final width = math.max(
          constraints.maxWidth,
          minBandWidth * equalizerBandFrequencies.length,
        );
        final height = MediaQuery.sizeOf(context).height < 640 ? 152.0 : 180.0;
        return SingleChildScrollView(
          key: const ValueKey('equalizer-bands-scroll'),
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (
                  var index = 0;
                  index < equalizerBandFrequencies.length;
                  index++
                )
                  Expanded(
                    child: _EqualizerBand(
                      index: index,
                      label: strings.equalizerBandName(index),
                      value: settings.gainsDb[index],
                      height: height,
                      onChanged: onChanged == null
                          ? null
                          : (gain) => onChanged!(index, gain),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _EqualizerBand extends StatelessWidget {
  const _EqualizerBand({
    required this.index,
    required this.label,
    required this.value,
    required this.height,
    required this.onChanged,
  });

  final int index;
  final String label;
  final double value;
  final double height;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final frequency = label.split(' ');
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        ExcludeSemantics(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: .45),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                // A fixed two-line value/unit arrangement keeps every slider
                // aligned even when fractional gains need a wider label.
                formatEqualizerGain(value).replaceFirst(' ', '\n'),
                key: ValueKey('equalizer-band-$index-gain'),
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: onChanged != null && value.abs() >= .01
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 14,
                  height: 1,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: .25),
                ),
              ),
              Positioned.fill(
                child: Semantics(
                  label: label,
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Slider(
                      key: ValueKey('equalizer-band-$index'),
                      value: value,
                      min: equalizerMinGainDb,
                      max: equalizerMaxGainDb,
                      divisions: 48,
                      label: formatEqualizerGain(value),
                      semanticFormatterCallback: formatEqualizerGain,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      onChanged: onChanged,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ExcludeSemantics(
          child: Column(
            children: [
              Text(
                frequency.first,
                style: textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(frequency.skip(1).join(' '), style: textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

/// Use the existing painted card resources; the audio controls do not need a
/// backdrop filter or an additional continuously rendered visual effect.
class _EqualizerSurface extends StatelessWidget {
  const _EqualizerSurface({
    required this.child,
    this.highlighted = false,
    super.key,
  });

  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => AppCardGradientBorder(
    solidInLiquidGlass: true,
    radius: 20,
    child: Material(
      color: highlighted
          ? Color.alphaBlend(
              Theme.of(context).colorScheme.primary.withValues(alpha: .045),
              AppColors.cardSurfaceFor(context),
            )
          : AppColors.cardSurfaceFor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}
