import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/platform/app_platform.dart';
import 'scrolled_under_tab_frame.dart';
import '../providers/app_strings.dart';
import '../providers/player_style.dart';

const _styleCaptionHorizontalPadding = 10.0;

/// Settings gallery backed by small, bundled snapshots of each player layout.
class PlayerStyleGalleryPage extends StatefulWidget {
  const PlayerStyleGalleryPage({
    required this.style,
    required this.strings,
    required this.header,
    required this.onChanged,
    this.bottomContentPadding = 0,
    super.key,
  });

  final PlayerStyle style;
  final AppStrings strings;
  final Widget header;
  final Future<void> Function(PlayerStyle) onChanged;
  final double bottomContentPadding;

  @override
  State<PlayerStyleGalleryPage> createState() => _PlayerStyleGalleryPageState();
}

class _PlayerStyleGalleryPageState extends State<PlayerStyleGalleryPage> {
  late PlayerStyle selected = widget.style;
  bool applying = false;

  Future<void> _select(PlayerStyle style) async {
    if (applying || style == selected) return;
    final previous = selected;
    setState(() {
      selected = style;
      applying = true;
    });
    try {
      await widget.onChanged(style);
    } catch (_) {
      if (mounted) {
        setState(() => selected = previous);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(widget.strings.error)));
      }
    } finally {
      // This flag only guards taps; completing a save does not change the UI.
      applying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return LayoutBuilder(
      builder: (context, viewport) {
        final maximumPreviewHeight =
            (viewport.maxHeight - widget.bottomContentPadding - 210).clamp(
              180.0,
              400.0,
            );
        return ScrolledUnderTabFrame(
          key: const ValueKey('settings-player-style-gallery'),
          surfaceKey: const ValueKey(
            'settings-detail-header-surface-playerStyles',
          ),
          scrollKey: const ValueKey('settings-detail-scroll-playerStyles'),
          header: widget.header,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  16,
                  12,
                  widget.bottomContentPadding + 28,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(strings.playerStyleGalleryHint),
                        const SizedBox(height: 20),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            const spacing = 12.0;
                            final textScale = math.max(
                              1.0,
                              MediaQuery.textScalerOf(context).scale(14) / 14,
                            );
                            final minimumCardWidth =
                                (constraints.maxWidth / 4).clamp(140.0, 220.0) *
                                textScale;
                            final columns =
                                ((constraints.maxWidth + spacing) /
                                        (minimumCardWidth + spacing))
                                    .floor()
                                    .clamp(1, PlayerStyle.values.length);
                            final width = math.min(
                              220.0 * textScale,
                              (constraints.maxWidth - spacing * (columns - 1)) /
                                  columns,
                            );
                            final previewHeight = math.min(
                              maximumPreviewHeight,
                              width * 800 / 380,
                            );
                            final titleStyle =
                                Theme.of(context).textTheme.titleSmall ??
                                const TextStyle(fontSize: 14);
                            final titlePainter = TextPainter(
                              textAlign: TextAlign.center,
                              textDirection: Directionality.of(context),
                              textScaler: MediaQuery.textScalerOf(context),
                              locale: Localizations.maybeLocaleOf(context),
                            );
                            var titleHeight = 0.0;
                            try {
                              // Reserve the tallest translated label at this
                              // width so previews and captions align.
                              for (final style in PlayerStyle.values) {
                                titlePainter.text = TextSpan(
                                  text: strings.playerStyleLabel(style),
                                  style: titleStyle,
                                );
                                titlePainter.layout(
                                  maxWidth: math.max(
                                    0.0,
                                    width - _styleCaptionHorizontalPadding * 2,
                                  ),
                                );
                                titleHeight = math.max(
                                  titleHeight,
                                  titlePainter.height,
                                );
                              }
                            } finally {
                              titlePainter.dispose();
                            }
                            return Wrap(
                              alignment: WrapAlignment.center,
                              spacing: spacing,
                              runSpacing: 16,
                              children: [
                                for (final style in PlayerStyle.values)
                                  SizedBox(
                                    width: width,
                                    child: _StylePreviewCard(
                                      key: ValueKey(
                                        'settings-player-style-option-${_optionCode(style)}',
                                      ),
                                      style: style,
                                      label: strings.playerStyleLabel(style),
                                      selected: selected == style,
                                      previewHeight: previewHeight,
                                      titleStyle: titleStyle,
                                      titleHeight: titleHeight,
                                      onTap: () => _select(style),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

String _optionCode(PlayerStyle style) => switch (style) {
  PlayerStyle.bstreamMusic => 'bstream-music',
  PlayerStyle.appleMusic => 'apple-music',
  PlayerStyle.classicVinyl => 'classic-vinyl',
  PlayerStyle.spotifyMusic => 'spotify-music',
};

class _StylePreviewCard extends StatelessWidget {
  const _StylePreviewCard({
    required this.style,
    required this.label,
    required this.selected,
    required this.previewHeight,
    required this.titleStyle,
    required this.titleHeight,
    required this.onTap,
    super.key,
  });
  final PlayerStyle style;
  final String label;
  final bool selected;
  final double previewHeight;
  final TextStyle titleStyle;
  final double titleHeight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final caption = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: _styleCaptionHorizontalPadding,
        vertical: 10,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: titleHeight),
        child: Center(
          child: Text(label, textAlign: TextAlign.center, style: titleStyle),
        ),
      ),
    );
    // Selection changes only the border and semantic state. Retain the same
    // image subtree until the actual app theme changes.
    final preview = switch (style) {
      PlayerStyle.bstreamMusic => const PlayerStylePreview(
        style: PlayerStyle.bstreamMusic,
      ),
      PlayerStyle.appleMusic => const PlayerStylePreview(
        style: PlayerStyle.appleMusic,
      ),
      PlayerStyle.classicVinyl => const PlayerStylePreview(
        style: PlayerStyle.classicVinyl,
      ),
      PlayerStyle.spotifyMusic => const PlayerStylePreview(
        style: PlayerStyle.spotifyMusic,
      ),
    };
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: previewHeight,
                child: Center(child: preview),
              ),
              caption,
            ],
          ),
        ),
      ),
    );
  }
}

/// The illustrations are rendered offline by tool/preview_assets. Opening the
/// gallery only decodes the active palette, without mounting miniature players,
/// loading their fonts, sampling backdrops, or creating per-card themes.
class PlayerStylePreview extends StatelessWidget {
  const PlayerStylePreview({required this.style, super.key});
  final PlayerStyle style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark =
        AppPlatform.isMobileTargetPlatform(theme.platform) ||
        theme.brightness == Brightness.dark;
    final palette = dark ? 'dark' : 'light';
    return AspectRatio(
      key: ValueKey('player-style-preview-${style.code}'),
      aspectRatio: 380 / 800,
      child: RepaintBoundary(
        child: Image.asset(
          'assets/player_styles/$palette/${style.code}.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.low,
          gaplessPlayback: true,
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}
