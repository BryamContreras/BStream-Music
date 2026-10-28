import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dialog.dart';
import '../../../../core/utils/cached_artwork_image_provider.dart';
import '../../../../core/utils/image_source.dart';
import '../../../../core/widgets/app_menu_bottom_sheet.dart';
import '../providers/lyrics_share_providers.dart';
import '../providers/music_providers.dart';
import 'device_audio_artwork_image_provider.dart';
import 'lyrics_share_photo_cropper.dart';

/// A snapshot: playback can continue without changing the image being edited.
@immutable
class LyricsShareCardData {
  LyricsShareCardData({
    required this.title,
    required this.artist,
    required List<String> lines,
    this.artworkSource,
    this.artworkFallbackSource,
  }) : lines = List.unmodifiable(
         lines
             .map((line) => line.trim())
             .where((line) => line.isNotEmpty)
             .take(5),
       );

  final String title;
  final String artist;
  final List<String> lines;
  final String? artworkSource;
  final String? artworkFallbackSource;
}

Future<void> showLyricsSharePreview({
  required BuildContext context,
  required LyricsShareCardData data,
}) async {
  if (data.lines.isEmpty) return;
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LyricsSharePreview(data: data),
    ),
  );
}

/// A static image editor. Only the visible card is rasterized when exporting.
class LyricsSharePreview extends ConsumerStatefulWidget {
  const LyricsSharePreview({required this.data, super.key});

  final LyricsShareCardData data;

  @override
  ConsumerState<LyricsSharePreview> createState() => _LyricsSharePreviewState();
}

enum _Background { blur, artwork, gradient, gallery }

enum _TextTone { automatic, light, dark }

enum _ExportAction { share, save }

class _LyricsSharePreviewState extends ConsumerState<LyricsSharePreview> {
  static const _logo = AssetImage('assets/icons/bstream_icon.png');
  static const _presets = <(Color, Color)>[
    (Color(0xFF9DAAFF), Color(0xFFCCB1EB)),
    (Color(0xFF69D7A1), Color(0xFF93D8DE)),
    (Color(0xFFFFB8A5), Color(0xFFF0A7D4)),
    (Color(0xFFFFDA8B), Color(0xFFEAA178)),
    (Color(0xFF254E70), Color(0xFF29344E)),
    (Color(0xFF463168), Color(0xFF182C47)),
  ];
  static const _colors = <Color>[
    Color(0xFF9DAAFF),
    Color(0xFFCCB1EB),
    Color(0xFFAA7EE8),
    Color(0xFF69D7A1),
    Color(0xFF93D8DE),
    Color(0xFF40B8C8),
    Color(0xFFFFB8A5),
    Color(0xFFF0A7D4),
    Color(0xFFE87999),
    Color(0xFFFFDA8B),
    Color(0xFFEAA178),
    Color(0xFFE95D44),
    Color(0xFF254E70),
    Color(0xFF29344E),
    Color(0xFF463168),
    Color(0xFF182C47),
    Color(0xFF283F36),
    Color(0xFFF0EEE7),
  ];

  final _cardKey = GlobalKey();
  final _shareButtonKey = GlobalKey();
  final _cancelArtworkLoads = <VoidCallback>{};
  _Background _background = _Background.artwork;
  _TextTone _textTone = _TextTone.automatic;
  Color _first = _presets.first.$1;
  Color _second = _presets.first.$2;
  ImageInfo? _artwork;
  ui.Image? _galleryPhoto;
  Rect? _galleryCrop;
  bool _preparing = true;
  bool _prepared = false;
  bool _busy = false;
  bool _choosingAction = false;
  bool _choosingPhoto = false;

  bool get _withinTextLimit =>
      widget.data.lines.fold<int>(0, (length, line) => length + line.length) <=
      12000;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prepared) return;
    _prepared = true;
    if (!_withinTextLimit) return;
    unawaited(_prepareArtwork());
  }

  Future<void> _prepareArtwork() async {
    // Resolve exactly once. Preview and exported PNG then use the same pixels,
    // including the thumbnail, with no network request during capture.
    final sources = <String>{
      if (widget.data.artworkSource?.trim() case final String source
          when source.isNotEmpty)
        source,
      if (widget.data.artworkFallbackSource?.trim() case final String fallback
          when fallback.isNotEmpty)
        fallback,
    };
    final configuration = createLocalImageConfiguration(context);
    ImageInfo? artwork;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    final logoReady = precacheImage(_logo, context, onError: (_, _) {});
    for (final source in sources) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero || !mounted) break;
      try {
        artwork = await _resolveArtwork(source, configuration, remaining);
        break;
      } catch (_) {
        // The fallback remains a valid, shareable design when offline.
      }
    }
    await logoReady;
    if (!mounted) {
      artwork?.dispose();
      return;
    }
    setState(() {
      _artwork = artwork;
      _preparing = false;
    });
  }

  Future<ImageInfo> _resolveArtwork(
    String source,
    ImageConfiguration configuration,
    Duration timeout,
  ) async {
    final deviceUri = deviceAudioUriFromArtworkSource(source);
    final ImageProvider provider;
    if (deviceUri != null) {
      provider = DeviceAudioArtworkImageProvider(
        audioUri: deviceUri,
        targetWidth: 1080,
      );
    } else if (isNetworkImageSource(source)) {
      provider = CachedArtworkImageProvider(source);
    } else {
      final file = imageFileFromSource(source);
      if (file == null || !await file.exists()) {
        throw const FileSystemException('Artwork is unavailable');
      }
      provider = FileImage(file);
    }
    if (!mounted) throw StateError('Preview closed');
    final stream = ResizeImage(
      provider,
      width: 1080,
      height: 1080,
      policy: ResizeImagePolicy.fit,
    ).resolve(configuration);
    final completion = Completer<ImageInfo>();
    ImageInfo? received;
    var delivered = false;
    final listener = ImageStreamListener(
      (info, _) {
        if (completion.isCompleted) {
          info.dispose();
        } else {
          received = info;
          completion.complete(info);
        }
      },
      onError: (Object error, StackTrace? stack) {
        if (!completion.isCompleted) completion.completeError(error, stack);
      },
    );
    void cancel() {
      if (!completion.isCompleted) {
        completion.completeError(StateError('Preview closed'));
      }
    }

    _cancelArtworkLoads.add(cancel);
    stream.addListener(listener);
    try {
      final result = await completion.future.timeout(timeout);
      delivered = true;
      return result;
    } finally {
      _cancelArtworkLoads.remove(cancel);
      stream.removeListener(listener);
      if (!delivered) received?.dispose();
    }
  }

  @override
  void dispose() {
    for (final cancel in _cancelArtworkLoads.toList(growable: false)) {
      cancel();
    }
    _artwork?.dispose();
    _galleryPhoto?.dispose();
    super.dispose();
  }

  void _selectBackground(_Background background) {
    if (background == _Background.gallery && _galleryPhoto == null) {
      unawaited(_chooseGalleryPhoto());
      return;
    }
    if (background == _background) return;
    setState(() {
      _background = background;
      _textTone = _TextTone.automatic;
    });
  }

  Future<void> _chooseGalleryPhoto() async {
    if (_choosingPhoto || _preparing || _busy) return;
    final service = ref.read(lyricsSharePhotoServiceProvider);
    final failure = ref.read(appStringsProvider).lyricsSharePhotoFailed;
    setState(() => _choosingPhoto = true);
    ui.Image? selected;
    try {
      selected = await service.pickPhoto();
      if (!mounted || selected == null) return;
      final layout = _CardLayout.measure(
        widget.data,
        Theme.of(context).textTheme,
      );
      final crop = await showLyricsSharePhotoCropper(
        context: context,
        image: selected,
        aspectRatio: _CardLayout.width / layout.height,
      );
      if (!mounted || crop == null) return;
      final previous = _galleryPhoto;
      setState(() {
        _galleryPhoto = selected;
        _galleryCrop = crop;
        _background = _Background.gallery;
        _textTone = _TextTone.automatic;
      });
      selected = null;
      // Release the previous background after its last preview frame.
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    } catch (_) {
      if (mounted) _message(failure);
    } finally {
      selected?.dispose();
      if (mounted) setState(() => _choosingPhoto = false);
    }
  }

  Future<void> _adjustGalleryPhoto() async {
    final photo = _galleryPhoto;
    if (photo == null || _choosingPhoto || _busy) return;
    setState(() => _choosingPhoto = true);
    try {
      final layout = _CardLayout.measure(
        widget.data,
        Theme.of(context).textTheme,
      );
      final crop = await showLyricsSharePhotoCropper(
        context: context,
        image: photo,
        aspectRatio: _CardLayout.width / layout.height,
        initialCrop: _galleryCrop,
      );
      if (mounted && crop != null && crop != _galleryCrop) {
        setState(() {
          _galleryCrop = crop;
          _textTone = _TextTone.automatic;
        });
      }
    } catch (_) {
      if (mounted) {
        _message(ref.read(appStringsProvider).lyricsSharePhotoFailed);
      }
    } finally {
      if (mounted) setState(() => _choosingPhoto = false);
    }
  }

  Future<void> _chooseColor(bool first) async {
    final strings = ref.read(appStringsProvider);
    final selected = first ? _first : _second;
    final color = await showAppDialog<Color>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(strings.lyricsShareColorLabel(first ? 1 : 2)),
        content: SizedBox(
          width: 280,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var index = 0; index < _colors.length; index++)
                _ColorSwatch(
                  key: ValueKey('lyrics-share-palette-color-$index'),
                  colors: [_colors[index], _colors[index]],
                  selected: selected == _colors[index],
                  label: '${strings.lyricsSharePalette} ${index + 1}',
                  onPressed: () => Navigator.of(context).pop(_colors[index]),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.cancel),
          ),
        ],
      ),
    );
    if (color != null && color != selected && mounted) {
      setState(() {
        if (first) {
          _first = color;
        } else {
          _second = color;
        }
        _textTone = _TextTone.automatic;
      });
    }
  }

  Future<void> _chooseExport() async {
    if (_busy || _preparing || _choosingAction || _choosingPhoto) return;
    _choosingAction = true;
    final strings = ref.read(appStringsProvider);
    final service = ref.read(lyricsImageShareServiceProvider);
    final renderBox = _shareButtonKey.currentContext?.findRenderObject();
    final origin = renderBox is RenderBox && renderBox.hasSize
        ? renderBox.localToGlobal(Offset.zero) & renderBox.size
        : const Rect.fromLTWH(1, 1, 1, 1);
    final action = await showAppMenuBottomSheet<_ExportAction>(
      context: context,
      artworkColor: _first,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (service.canShare)
              ListTile(
                key: const ValueKey('lyrics-share-native'),
                leading: const Icon(Icons.ios_share_rounded),
                title: Text(strings.lyricsShareImage),
                onTap: () => Navigator.of(context).pop(_ExportAction.share),
              ),
            ListTile(
              key: const ValueKey('lyrics-share-save'),
              leading: const Icon(Icons.save_alt_rounded),
              title: Text(strings.lyricsShareSaveImage),
              onTap: () => Navigator.of(context).pop(_ExportAction.save),
            ),
          ],
        ),
      ),
    );
    _choosingAction = false;
    if (!mounted || action == null) return;
    setState(() => _busy = true);
    try {
      // Let the sheet disappear and the final font/image frame finish before
      // rasterizing. The card is the same boundary used by the preview.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final bytes = await _captureCard();
      if (!mounted) return;
      if (action == _ExportAction.share) {
        await service.shareImage(
          pngBytes: bytes,
          title: widget.data.title,
          sharePositionOrigin: origin,
        );
      } else {
        final saved = await service.saveImage(
          pngBytes: bytes,
          title: widget.data.title,
        );
        if (mounted && saved != null) _message(strings.lyricsShareSaved);
      }
    } catch (_) {
      if (mounted) _message(strings.lyricsShareFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List> _captureCard() async {
    final boundary = _cardKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) {
      throw StateError('Preview has not been laid out');
    }
    final image = await boundary.toImage(
      pixelRatio: 1080 / boundary.size.width,
    );
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG encoding failed');
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _textColorControl(AppStrings strings, bool enabled) {
    final foreground = _resolveTextColor(
      _textTone,
      photo: _hasPhotoBackground(
        _background,
        _artwork?.image,
        _galleryPhoto,
        _galleryCrop,
      ),
      first: _first,
      second: _second,
    );
    final light = foreground == Colors.white;
    final label = light
        ? strings.lyricsShareTextLight
        : strings.lyricsShareTextDark;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: strings.lyricsShareTextColor,
      child: OutlinedButton.icon(
        key: const ValueKey('lyrics-share-text-color'),
        onPressed: enabled
            ? () => setState(
                () => _textTone = light ? _TextTone.dark : _TextTone.light,
              )
            : null,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          backgroundColor: scheme.surface.withValues(alpha: .45),
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .7)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: Theme.of(context).textTheme.labelMedium,
        ),
        icon: const Icon(Icons.text_fields_rounded, size: 18),
        label: Text(label, maxLines: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    if (!_withinTextLimit) {
      return Scaffold(
        appBar: AppBar(title: Text(strings.lyricsShareTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(strings.lyricsShareFailed),
          ),
        ),
      );
    }
    final enabled = !_preparing && !_busy && !_choosingPhoto;
    final layout = _CardLayout.measure(widget.data, theme.textTheme);
    return Scaffold(
      key: const ValueKey('lyrics-share-preview-page'),
      appBar: AppBar(title: Text(strings.lyricsShareTitle)),
      body: SafeArea(
        top: false,
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow.withValues(
                        alpha: .55,
                      ),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: .45,
                        ),
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                strings.lyricsShareBackground,
                                style: theme.textTheme.labelLarge,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              flex: 2,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: _textColorControl(strings, enabled),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _EditorButtonGrid(
                          key: const ValueKey('lyrics-share-background'),
                          columns: 4,
                          children: [
                            for (final (background, label, icon) in [
                              (
                                _Background.gradient,
                                strings.lyricsShareGradient,
                                Icons.gradient_rounded,
                              ),
                              (
                                _Background.artwork,
                                strings.lyricsShareCover,
                                Icons.image_outlined,
                              ),
                              (
                                _Background.blur,
                                strings.lyricsShareBlur,
                                Icons.blur_on_rounded,
                              ),
                              (
                                _Background.gallery,
                                strings.lyricsShareGallery,
                                Icons.photo_library_outlined,
                              ),
                            ])
                              _EditorOptionButton(
                                key: ValueKey(
                                  'lyrics-share-background-${background.name}',
                                ),
                                icon: icon,
                                label: label,
                                selected: _background == background,
                                onPressed: enabled
                                    ? () => _selectBackground(background)
                                    : null,
                              ),
                          ],
                        ),
                        if (_background == _Background.gallery) ...[
                          const SizedBox(height: 8),
                          _EditorButtonGrid(
                            compact: true,
                            children: [
                              _EditorOptionButton(
                                key: const ValueKey(
                                  'lyrics-share-choose-photo',
                                ),
                                onPressed: enabled ? _chooseGalleryPhoto : null,
                                icon: Icons.photo_library_outlined,
                                label: strings.lyricsShareChoosePhoto,
                                compact: true,
                              ),
                              _EditorOptionButton(
                                key: const ValueKey(
                                  'lyrics-share-adjust-photo',
                                ),
                                onPressed: enabled ? _adjustGalleryPhoto : null,
                                icon: Icons.crop_rounded,
                                label: strings.lyricsShareAdjustPhoto,
                                compact: true,
                              ),
                            ],
                          ),
                        ],
                        if (_background == _Background.gradient) ...[
                          const SizedBox(height: 16),
                          Text(
                            strings.lyricsSharePalette,
                            style: theme.textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (
                                var index = 0;
                                index < _presets.length;
                                index++
                              )
                                _ColorSwatch(
                                  key: ValueKey('lyrics-share-preset-$index'),
                                  colors: [
                                    _presets[index].$1,
                                    _presets[index].$2,
                                  ],
                                  label:
                                      '${strings.lyricsSharePalette} ${index + 1}',
                                  selected:
                                      _first == _presets[index].$1 &&
                                      _second == _presets[index].$2,
                                  onPressed: enabled
                                      ? () => setState(() {
                                          if (_first == _presets[index].$1 &&
                                              _second == _presets[index].$2) {
                                            return;
                                          }
                                          _first = _presets[index].$1;
                                          _second = _presets[index].$2;
                                          _textTone = _TextTone.automatic;
                                        })
                                      : null,
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _EditorButtonGrid(
                            compact: true,
                            children: [
                              for (var index = 1; index <= 2; index++)
                                _EditorOptionButton(
                                  key: ValueKey('lyrics-share-color-$index'),
                                  onPressed: enabled
                                      ? () => _chooseColor(index == 1)
                                      : null,
                                  swatch: index == 1 ? _first : _second,
                                  label: strings.lyricsShareColorLabel(index),
                                  compact: true,
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    label: strings.lyricsSharePreview,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: AspectRatio(
                          aspectRatio: _CardLayout.width / layout.height,
                          child: RepaintBoundary(
                            key: _cardKey,
                            child: FittedBox(
                              fit: BoxFit.contain,
                              child: SizedBox(
                                width: _CardLayout.width,
                                height: layout.height,
                                child: _LyricsCard(
                                  data: widget.data,
                                  layout: layout,
                                  artwork: _artwork?.image,
                                  background: _background,
                                  galleryPhoto: _galleryPhoto,
                                  galleryCrop: _galleryCrop,
                                  textTone: _textTone,
                                  first: _first,
                                  second: _second,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: _shareButtonKey,
                  onPressed: enabled ? _chooseExport : null,
                  icon: !enabled
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                  label: Text(
                    !enabled
                        ? strings.lyricsSharePreparing
                        : strings.lyricsShareTitle,
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

/// Uses full-size buttons instead of chips that shrink around their labels.
/// Four choices form a single desktop row or two equal phone rows.
class _EditorButtonGrid extends StatelessWidget {
  const _EditorButtonGrid({
    required this.children,
    this.columns = 2,
    this.compact = false,
    super.key,
  });

  final List<Widget> children;
  final int columns;
  final bool compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = math.max(
        1.0,
        MediaQuery.textScalerOf(context).scale(13) / 13,
      );
      var count = columns;
      while (count > 1 &&
          (constraints.maxWidth - (count - 1) * 8) / count < 120 * scale) {
        count = (count / 2).ceil();
      }
      final height = (compact ? 42.0 : 48.0) * scale;
      return Column(
        children: [
          for (var start = 0; start < children.length; start += count) ...[
            if (start > 0) const SizedBox(height: 8),
            Row(
              children: [
                for (var column = 0; column < count; column++) ...[
                  if (column > 0) const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: height,
                      child: start + column < children.length
                          ? children[start + column]
                          : null,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      );
    },
  );
}

class _EditorOptionButton extends StatelessWidget {
  const _EditorOptionButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.swatch,
    this.selected = false,
    this.compact = false,
    super.key,
  });

  final String label;
  final IconData? icon;
  final Color? swatch;
  final VoidCallback? onPressed;
  final bool selected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      enabled: onPressed != null,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          foregroundColor: selected
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
          backgroundColor: selected
              ? scheme.primary.withValues(alpha: .16)
              : scheme.surface.withValues(alpha: .35),
          side: BorderSide(
            color: selected
                ? scheme.primary.withValues(alpha: .65)
                : scheme.outlineVariant.withValues(alpha: .7),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: theme.textTheme.labelMedium?.copyWith(
            fontSize: compact ? 12 : 13,
            fontWeight: FontWeight.w600,
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (swatch != null) ...[
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.onSurface.withValues(alpha: .25),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ] else if (icon != null) ...[
              Icon(icon, size: 18),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(label, maxLines: 2, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.colors,
    required this.selected,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final List<Color> colors;
  final bool selected;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    button: true,
    selected: selected,
    child: SizedBox.square(
      dimension: 44,
      child: Material(
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: .2),
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: InkWell(
            onTap: onPressed,
            child: selected
                ? Icon(Icons.check_rounded, color: _foregroundFor(colors))
                : null,
          ),
        ),
      ),
    ),
  );
}

bool _hasPhotoBackground(
  _Background background,
  ui.Image? artwork,
  ui.Image? galleryPhoto,
  Rect? galleryCrop,
) => switch (background) {
  _Background.blur || _Background.artwork => artwork != null,
  _Background.gallery => galleryPhoto != null && galleryCrop != null,
  _Background.gradient => false,
};

Color _resolveTextColor(
  _TextTone tone, {
  required bool photo,
  required Color first,
  required Color second,
}) => switch (tone) {
  _TextTone.automatic => photo ? Colors.white : _foregroundFor([first, second]),
  _TextTone.light => Colors.white,
  _TextTone.dark => const Color(0xFF12151B),
};

Color _foregroundFor(List<Color> colors) {
  var whiteContrast = double.infinity;
  var blackContrast = double.infinity;
  final samples = [...colors, Color.lerp(colors.first, colors.last, .5)!];
  for (final color in samples) {
    final luminance = color.computeLuminance();
    whiteContrast = math.min(whiteContrast, 1.05 / (luminance + .05));
    blackContrast = math.min(blackContrast, (luminance + .05) / .05);
  }
  return whiteContrast > blackContrast ? Colors.white : const Color(0xFF12151B);
}

Color _contrastScrim(
  List<Color> colors,
  Color foreground, {
  double maximumOpacity = .76,
}) {
  final lightText = foreground == Colors.white;
  final tint = lightText ? Colors.black : Colors.white;
  final textLuminance = foreground.computeLuminance();
  for (var opacity = 0.0; opacity < maximumOpacity; opacity += .04) {
    final overlay = tint.withValues(alpha: opacity);
    final readable = colors.every((color) {
      final luminance = Color.alphaBlend(overlay, color).computeLuminance();
      final contrast =
          (math.max(luminance, textLuminance) + .05) /
          (math.min(luminance, textLuminance) + .05);
      return contrast >= 4.5;
    });
    if (readable) return overlay;
  }
  return tint.withValues(alpha: maximumOpacity);
}

/// Canonical document dimensions keep accessibility scaling in the controls
/// without changing the image's typography or its exported layout.
class _CardLayout {
  const _CardLayout({required this.height, required this.lyricStyle});

  static const width = 360.0;
  static const padding = 30.0;
  final double height;
  final TextStyle lyricStyle;

  static _CardLayout measure(LyricsShareCardData data, TextTheme theme) {
    var size = 23.0;
    double measure(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: data.lines.join('\n'), style: style),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: width - padding * 2);
      final height = painter.height;
      painter.dispose();
      return height;
    }

    TextStyle style() => TextStyle(
      fontFamily: theme.bodyMedium?.fontFamily,
      fontFamilyFallback: theme.bodyMedium?.fontFamilyFallback,
      fontSize: size,
      fontWeight: FontWeight.w700,
      height: 1.28,
      letterSpacing: -.25,
    );
    var lyricHeight = measure(style());
    // Five unusually long lines remain complete; reduce only this static
    // document's typography to keep the PNG below 1080 × 2880 pixels.
    while (lyricHeight > 680 && size > 8) {
      size -= 1;
      lyricHeight = measure(style());
    }
    return _CardLayout(
      height: math.max(360, math.min(960, lyricHeight + 230)),
      lyricStyle: style(),
    );
  }
}

class _LyricsCard extends StatelessWidget {
  const _LyricsCard({
    required this.data,
    required this.layout,
    required this.artwork,
    required this.background,
    required this.galleryPhoto,
    required this.galleryCrop,
    required this.textTone,
    required this.first,
    required this.second,
  });

  final LyricsShareCardData data;
  final _CardLayout layout;
  final ui.Image? artwork;
  final _Background background;
  final ui.Image? galleryPhoto;
  final Rect? galleryCrop;
  final _TextTone textTone;
  final Color first;
  final Color second;

  @override
  Widget build(BuildContext context) {
    final photo = _hasPhotoBackground(
      background,
      artwork,
      galleryPhoto,
      galleryCrop,
    );
    final foreground = _resolveTextColor(
      textTone,
      photo: photo,
      first: first,
      second: second,
    );
    final manual = textTone != _TextTone.automatic;
    final scrim = photo
        ? Colors.transparent
        : _contrastScrim(
            [first, second],
            foreground,
            maximumOpacity: manual ? .30 : .76,
          );
    // A small static edge shadow supports the lighter tint without another
    // filter or continuously animated layer over the image.
    final textShadows = photo || manual
        ? foreground == Colors.white
              ? const [
                  Shadow(
                    color: Color(0x99000000),
                    offset: Offset(0, 1),
                    blurRadius: 1.5,
                  ),
                ]
              : const [
                  Shadow(
                    color: Color(0x99FFFFFF),
                    offset: Offset(0, 1),
                    blurRadius: 1.5,
                  ),
                ]
        : null;
    return MediaQuery.withNoTextScaling(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [first, second],
                ),
              ),
            ),
            if (photo) ...[
              if (background == _Background.gallery)
                CustomPaint(
                  key: const ValueKey('lyrics-share-gallery-photo'),
                  painter: _GalleryBackgroundPainter(
                    galleryPhoto!,
                    galleryCrop!,
                  ),
                )
              else if (background == _Background.blur)
                ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: RawImage(image: artwork, fit: BoxFit.cover),
                )
              else
                RawImage(image: artwork, fit: BoxFit.cover),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: foreground == Colors.white
                        ? const [Color(0x52000000), Color(0x75000000)]
                        : const [Color(0x52FFFFFF), Color(0x75FFFFFF)],
                  ),
                ),
              ),
            ] else if (scrim.a > 0)
              ColoredBox(color: scrim),
            Padding(
              padding: const EdgeInsets.all(_CardLayout.padding),
              child: DefaultTextStyle(
                style: TextStyle(
                  fontFamily: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.fontFamily,
                  color: foreground,
                  shadows: textShadows,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: SizedBox.square(
                            dimension: 52,
                            child: artwork == null
                                ? ColoredBox(
                                    color: foreground.withValues(alpha: .12),
                                    child: Icon(
                                      Icons.music_note_rounded,
                                      color: foreground,
                                    ),
                                  )
                                : RawImage(image: artwork, fit: BoxFit.cover),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                data.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                data.artist,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: _CardLayout.width - _CardLayout.padding * 2,
                            child: Text(
                              data.lines.join('\n'),
                              key: const ValueKey('lyrics-share-card-lines'),
                              style: layout.lyricStyle.copyWith(
                                color: foreground,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: Image.asset(
                            'assets/icons/bstream_icon.png',
                            width: 28,
                            height: 28,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'BStream Music',
                          style: TextStyle(
                            color: foreground,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Uses the approved source rectangle directly, so exporting never decodes or
/// recompresses the photo and preserves the exact crop shown in the editor.
class _GalleryBackgroundPainter extends CustomPainter {
  const _GalleryBackgroundPainter(this.image, this.crop);

  final ui.Image image;
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        crop.left * image.width,
        crop.top * image.height,
        crop.width * image.width,
        crop.height * image.height,
      ),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_GalleryBackgroundPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.crop != crop;
}
