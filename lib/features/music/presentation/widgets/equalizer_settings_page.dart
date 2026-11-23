import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/widgets/app_shared_widgets.dart';
import 'equalizer_band_guides.dart';
import 'equalizer_fader_shapes.dart';
import 'equalizer_preset_icon.dart';
import 'glass_popup_menu_button.dart';
import 'playback_gradient_background.dart';
import 'scrolled_under_tab_frame.dart';
import '../providers/equalizer_providers.dart';
import '../providers/music_providers.dart';

String _formatEqualizerGain(double gain) {
  final digits = gain == gain.roundToDouble() ? 0 : 1;
  return '${gain > 0 ? '+' : ''}${gain.toStringAsFixed(digits)} dB';
}

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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final enlargedCompactText =
        MediaQuery.sizeOf(context).width < 480 &&
        MediaQuery.textScalerOf(context).scale(14) > 18;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
        key: const ValueKey('equalizer-settings-page'),
        body: Stack(
          fit: StackFit.expand,
          children: [
            const BrowsingTabBackground(showCustomPhoto: true),
            SafeArea(
              child: ScrolledUnderTabFrame(
                surfaceKey: const ValueKey('equalizer-header-surface'),
                scrollKey: const ValueKey('equalizer-settings-scroll'),
                header: Row(
                  children: [
                    const BackButton(key: ValueKey('equalizer-back')),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        strings.equalizer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                slivers: [
                  settings.when(
                    loading: () => const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (_, _) => SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text(strings.equalizerError)),
                    ),
                    data: (state) {
                      final equalizer = state.equalizer.normalized;
                      final canAdjust = available && equalizer.enabled;
                      final controller = ref.read(
                        settingsControllerProvider.notifier,
                      );
                      void update(Future<void> Function() action) =>
                          unawaited(_save(context, ref, action));

                      return SliverPadding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        sliver: SliverToBoxAdapter(
                          child: _EqualizerPanelLayout(
                            power: _EqualizerSurface(
                              key: const ValueKey('equalizer-power-card'),
                              highlighted: available && equalizer.enabled,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SwitchListTile.adaptive(
                                    key: const ValueKey('equalizer-enabled'),
                                    dense: false,
                                    visualDensity: VisualDensity.standard,
                                    minTileHeight:
                                        appListCardIconSize +
                                        appTrackRowPaddingVertical * 2,
                                    secondary: enlargedCompactText
                                        ? null
                                        : _PresetBarsGlyph(
                                            gains: equalizer.gainsDb,
                                            active: canAdjust,
                                            size: appListCardIconSize,
                                          ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: appTrackRowPaddingHorizontal,
                                    ),
                                    title: Text(
                                      strings.equalizerEnabled,
                                      style: appListCardTitleStyle(context),
                                    ),
                                    subtitle: enlargedCompactText
                                        ? null
                                        : Padding(
                                            padding: const EdgeInsets.only(
                                              top: 2,
                                            ),
                                            child: Text(
                                              equalizer.enabled
                                                  ? strings.equalizerActive
                                                  : strings.equalizerInactive,
                                              style: appListCardSubtitleStyle(
                                                context,
                                              ),
                                            ),
                                          ),
                                    value: equalizer.enabled,
                                    onChanged: available
                                        ? (enabled) => update(
                                            () => controller.setEqualizer(
                                              ref
                                                  .read(
                                                    settingsControllerProvider,
                                                  )
                                                  .requireValue
                                                  .equalizer
                                                  .copyWith(enabled: enabled),
                                            ),
                                          )
                                        : null,
                                  ),
                                  if (enlargedCompactText)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        12,
                                      ),
                                      child: Text(
                                        equalizer.enabled
                                            ? strings.equalizerActive
                                            : strings.equalizerInactive,
                                        style: appListCardSubtitleStyle(
                                          context,
                                        ),
                                      ),
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
                                                    ? strings
                                                          .equalizerCastUnavailable
                                                    : strings
                                                          .equalizerUnavailable
                                              : strings.equalizerError,
                                          key: const ValueKey(
                                            'equalizer-status-message',
                                          ),
                                          style: TextStyle(
                                            color:
                                                runtime.error != null &&
                                                    available
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
                                        ? const LinearProgressIndicator(
                                            minHeight: 2,
                                          )
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                            presets: _EqualizerPresetControls(
                              selected: state.equalizerProfiles.selectedFor(
                                equalizer,
                              ),
                              strings: strings,
                              available: available,
                              onChoose: (preset) => update(
                                () => controller.selectEqualizerPreset(preset),
                              ),
                            ),
                            controls: _EqualizerBands(
                              key: const ValueKey('equalizer-controls'),
                              settings: equalizer,
                              strings: strings,
                              onChanged: canAdjust
                                  ? (index, gain) => update(
                                      () => controller.setEqualizerBand(
                                        index,
                                        gain,
                                      ),
                                    )
                                  : null,
                            ),
                            reset: OutlinedButton.icon(
                              key: const ValueKey('equalizer-reset'),
                              onPressed: available && !equalizer.isFlat
                                  ? () => update(
                                      () => controller.setEqualizer(
                                        ref
                                            .read(settingsControllerProvider)
                                            .requireValue
                                            .equalizer
                                            .copyWith(
                                              gainsDb:
                                                  EqualizerPreset.flat.gainsDb,
                                            ),
                                      ),
                                    )
                                  : null,
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: appListCardPaddingHorizontal,
                                  vertical: appListCardPaddingVertical,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    appCardRadius,
                                  ),
                                ),
                              ),
                              icon: const Icon(Icons.restart_alt_rounded),
                              label: Text(
                                strings.equalizerReset,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(ref.read(appStringsProvider).equalizerError)),
      );
    }
  }
}

class _EqualizerPanelLayout extends StatelessWidget {
  const _EqualizerPanelLayout({
    required this.power,
    required this.presets,
    required this.controls,
    required this.reset,
  });

  final Widget power;
  final Widget presets;
  final Widget controls;
  final Widget reset;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: appShelfPaddingHorizontal,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1060),
            child: power,
          ),
        ),
      ),
      const SizedBox(height: 12),
      presets,
      const SizedBox(height: 12),
      controls,
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: appContentMaxWidth),
            child: SizedBox(width: double.infinity, child: reset),
          ),
        ),
      ),
    ],
  );
}

class _EqualizerBands extends StatelessWidget {
  const _EqualizerBands({
    super.key,
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
      trackHeight: 4,
      trackShape: const EqualizerFaderTrackShape(),
      thumbShape: const EqualizerFaderThumbShape(),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
      inactiveTrackColor: Theme.of(
        context,
      ).colorScheme.onSurface.withValues(alpha: .12),
      disabledActiveTrackColor: Theme.of(
        context,
      ).colorScheme.onSurfaceVariant.withValues(alpha: .28),
      disabledInactiveTrackColor: Theme.of(
        context,
      ).colorScheme.onSurface.withValues(alpha: .08),
      showValueIndicator: ShowValueIndicator.never,
      activeTickMarkColor: Colors.transparent,
      inactiveTickMarkColor: Colors.transparent,
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // Keep ten slim faders in one row. Enlarged text uses wider columns
        // and scrolling so accessibility sizes retain their full labels.
        final gainStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          height: 1.1,
        );
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
        final media = MediaQuery.of(context);
        final enlarged = media.textScaler.scale(14) > 18;
        final minBandWidth = enlarged ? math.max(48.0, widestGain + 4) : 24.0;
        final width = math.max(
          constraints.maxWidth,
          minBandWidth * equalizerBandFrequencies.length,
        );
        final availableHeight = media.size.height - media.viewPadding.vertical;
        final height = enlarged
            ? math.max(224.0, minBandWidth + 8)
            : (availableHeight - 480).clamp(
                192.0,
                constraints.maxWidth < 560 ? 320.0 : 400.0,
              );
        return SingleChildScrollView(
          key: const ValueKey('equalizer-bands-scroll'),
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 4, bottom: 4),
                  child: Text(
                    'dB',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                Stack(
                  children: [
                    Positioned(
                      top: media.textScaler.scale(10.5) * 1.1 + 8,
                      left: 0,
                      right: 0,
                      height: height,
                      child: EqualizerBandGuides(
                        gainsDb: settings.gainsDb,
                        active: onChanged != null,
                      ),
                    ),
                    Row(
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
                  ],
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
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colors = theme.colorScheme;
    final adjusted = onChanged != null && value.abs() >= .01;
    return Column(
      children: [
        ExcludeSemantics(
          child: SizedBox(
            height: MediaQuery.textScalerOf(context).scale(10.5) * 1.1 + 4,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: adjusted
                      ? colors.primary.withValues(alpha: .1)
                      : colors.onSurface.withValues(alpha: .035),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: adjusted
                        ? colors.primary.withValues(alpha: .18)
                        : colors.onSurface.withValues(alpha: .045),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 2,
                  ),
                  child: Text(
                    // A shared dB legend leaves room for all ten controls in a row.
                    _formatEqualizerGain(value).replaceFirst(' dB', ''),
                    key: ValueKey('equalizer-band-$index-gain'),
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      color: adjusted
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ExcludeSemantics(
                child: EqualizerFaderScale(color: colors.onSurface),
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
                      label: _formatEqualizerGain(value),
                      semanticFormatterCallback: _formatEqualizerGain,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      onChanged: onChanged,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        ExcludeSemantics(
          child: Column(
            children: [
              SizedBox(
                height: MediaQuery.textScalerOf(context).scale(10) * 1.1,
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    frequency.first,
                    style: textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              Text(
                frequency.skip(1).join(' '),
                style: textTheme.labelSmall?.copyWith(
                  fontSize: 8.5,
                  height: 1.1,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shares the same painted material, tint and outline as settings cards.
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
    radius: 12,
    width: .7,
    emphasized: highlighted,
    child: Material(
      color: AppColors.cardSurfaceFor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.cardBorderFor(context, solidInLiquidGlass: true),
          width: .7,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}

class _EqualizerPresetControls extends StatefulWidget {
  const _EqualizerPresetControls({
    required this.selected,
    required this.strings,
    required this.available,
    required this.onChoose,
  });

  final EqualizerPreset selected;
  final AppStrings strings;
  final bool available;
  final ValueChanged<EqualizerPreset> onChoose;

  @override
  State<_EqualizerPresetControls> createState() =>
      _EqualizerPresetControlsState();
}

class _EqualizerPresetControlsState extends State<_EqualizerPresetControls> {
  late EqualizerPreset _lastBuiltIn = widget.selected == EqualizerPreset.custom
      ? EqualizerPreset.flat
      : widget.selected;

  @override
  void didUpdateWidget(covariant _EqualizerPresetControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != EqualizerPreset.custom) {
      _lastBuiltIn = widget.selected;
    }
  }

  List<PopupMenuEntry<EqualizerPreset>> _buildMenu(BuildContext context) {
    final iconColor = AppColors.menuIconFor(context);
    final selectedColor = Theme.of(context).colorScheme.primary;
    return [
      for (final preset in EqualizerPreset.values)
        if (preset != EqualizerPreset.custom)
          PopupMenuItem(
            key: ValueKey('equalizer-preset-${preset.name}'),
            value: preset,
            child: Row(
              children: [
                EqualizerPresetIcon(preset: preset, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(widget.strings.equalizerPresetName(preset)),
                ),
                if (preset == widget.selected) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check_rounded, size: 18, color: selectedColor),
                ],
              ],
            ),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final customSelected = widget.selected == EqualizerPreset.custom;
    final strings = widget.strings;
    return Semantics(
      key: const ValueKey('equalizer-presets'),
      label: strings.equalizerPresets,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1060),
            child: Row(
              children: [
                Expanded(
                  child: _EqualizerPresetCard(
                    key: const ValueKey('equalizer-preset-custom'),
                    label: strings.equalizerPresetName(EqualizerPreset.custom),
                    selected: customSelected,
                    enabled: widget.available,
                    buttonBuilder: (radius, label) => InkWell(
                      borderRadius: radius,
                      onTap: widget.available
                          ? () => widget.onChoose(EqualizerPreset.custom)
                          : null,
                      child: label,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _EqualizerPresetCard(
                    key: const ValueKey('equalizer-preset-picker'),
                    label: strings.equalizerPresetName(_lastBuiltIn),
                    selected: !customSelected,
                    enabled: widget.available,
                    trailing: const Icon(Icons.expand_more_rounded, size: 18),
                    buttonBuilder: (radius, label) =>
                        GlassPopupMenuButton<EqualizerPreset>(
                          borderRadius: radius,
                          position: PopupMenuPosition.under,
                          offset: const Offset(0, 4),
                          tooltip: strings.equalizerPresets,
                          constraints: const BoxConstraints(
                            minWidth: 216,
                            maxWidth: 320,
                          ),
                          enabled: widget.available,
                          onSelected: widget.onChoose,
                          itemBuilder: _buildMenu,
                          child: label,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EqualizerPresetCard extends StatelessWidget {
  const _EqualizerPresetCard({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.buttonBuilder,
    this.trailing,
    super.key,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final Widget Function(BorderRadius radius, Widget label) buttonBuilder;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final color = !enabled
        ? colors.onSurface.withValues(alpha: .38)
        : selected
        ? colors.onPrimaryContainer
        : AppColors.contentTitleFor(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final radius = BorderRadius.circular(appCardRadius);
    final style = (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
      fontSize: 13,
      color: color,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
    );
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      inMutuallyExclusiveGroup: true,
      child: AppCardGradientBorder(
        emphasized: selected,
        solidInLiquidGlass: true,
        width: selected ? 1.4 : 1,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected ? null : AppColors.cardSurfaceFor(context),
            gradient: selected
                ? AppColors.selectedCardGradientFor(context)
                : null,
            borderRadius: radius,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: buttonBuilder(
              radius,
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: AnimatedDefaultTextStyle(
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          style: style,
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      if (trailing != null)
                        IconTheme.merge(
                          data: IconThemeData(color: color),
                          child: trailing!,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small illustration of the saved profile, never a live spectrum.
class _PresetBarsGlyph extends StatelessWidget {
  const _PresetBarsGlyph({
    required this.gains,
    this.active = true,
    this.size = 40,
  });
  final List<double> gains;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = active ? colors.primary : colors.onSurfaceVariant;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: .18),
              color.withValues(alpha: .045),
            ],
          ),
          border: Border.all(color: color.withValues(alpha: .14)),
        ),
        child: CustomPaint(painter: _PresetBarsPainter(gains, color)),
      ),
    );
  }
}

class _PresetBarsPainter extends CustomPainter {
  const _PresetBarsPainter(this.gains, this.color);
  final List<double> gains;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final step = size.width / gains.length;
    for (var index = 0; index < gains.length; index++) {
      final height = size.height * (.3 + (gains[index] + 12) / 24 * .6);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            step * (index + .2),
            (size.height - height) / 2,
            step * .6,
            height,
          ),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PresetBarsPainter oldDelegate) =>
      color != oldDelegate.color ||
      gains.length != oldDelegate.gains.length ||
      List.generate(
        gains.length,
        (i) => gains[i] != oldDelegate.gains[i],
      ).any((changed) => changed);
}
