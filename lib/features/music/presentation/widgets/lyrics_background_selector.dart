import 'package:flutter/material.dart';

import '../providers/app_strings.dart';
import '../providers/lyrics_background_style.dart';

/// Background and animation share one continuous, theme-aware selector.
class LyricsAppearanceSelector<T> extends StatelessWidget {
  const LyricsAppearanceSelector({
    required this.value,
    required this.options,
    required this.onChanged,
    required this.keyPrefix,
    super.key,
  });

  final T value;
  final List<({T value, String code, String label})> options;
  final ValueChanged<T>? onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700);
    return LayoutBuilder(
      builder: (context, constraints) {
        final measure = TextPainter(
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          maxLines: 1,
        );
        var widestLabel = 0.0;
        try {
          for (final option in options) {
            measure.text = TextSpan(text: option.label, style: textStyle);
            measure.layout();
            if (measure.width > widestLabel) widestLabel = measure.width;
          }
        } finally {
          measure.dispose();
        }
        final vertical =
            (widestLabel + 24) * options.length > constraints.maxWidth;
        return SizedBox(
          width: constraints.maxWidth,
          child: SegmentedButton<T>(
            key: ValueKey('$keyPrefix-options'),
            selected: {value},
            showSelectedIcon: false,
            direction: vertical ? Axis.vertical : Axis.horizontal,
            expandedInsets: vertical ? null : EdgeInsets.zero,
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              textStyle: WidgetStatePropertyAll(textStyle),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            segments: [
              for (final option in options)
                ButtonSegment<T>(
                  value: option.value,
                  label: Text(
                    option.label,
                    key: ValueKey('$keyPrefix-option-${option.code}'),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
            onSelectionChanged: onChanged == null
                ? null
                : (selection) => onChanged!(selection.first),
          ),
        );
      },
    );
  }
}

class LyricsBackgroundSelector extends StatelessWidget {
  const LyricsBackgroundSelector({
    required this.value,
    required this.strings,
    required this.onChanged,
    this.keyPrefix = 'lyrics-background',
    super.key,
  });

  final LyricsBackgroundStyle value;
  final AppStrings strings;
  final ValueChanged<LyricsBackgroundStyle>? onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) =>
      LyricsAppearanceSelector<LyricsBackgroundStyle>(
        value: value,
        keyPrefix: keyPrefix,
        onChanged: onChanged,
        options: [
          for (final style in LyricsBackgroundStyle.values)
            (
              value: style,
              code: style.code,
              label: strings.lyricsBackgroundLabel(style),
            ),
        ],
      );
}
