import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Optical treatment for the exposed edge of a liquid-glass sheet.
enum LiquidGlassEdgeTreatment {
  /// A free-standing sheet with refraction, highlight and exterior depth on
  /// all four sides.
  perimeter,

  /// An edge-to-edge sheet integrated into the window chrome. Only its lower
  /// seam refracts and catches light, so it never reads as a boxed toolbar.
  bottom,

  /// A plain blurred sheet without a refractive edge.
  none,
}

/// A continuously clipped, backdrop-sampling liquid-glass sheet.
///
/// Its optical recipe follows the rounded-rectangle lens used by Echo Music:
/// saturated blur, a compact perimeter lens, a neutral material tint and a
/// two-stage chromatic bevel. Backdrop color reaches the contour through
/// refraction rather than a synthetic white border or a wide rainbow fringe.
class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.blurSigma = 8,
    this.intensity = 1,
    this.clipBehavior = Clip.antiAlias,
    this.backdropGroupKey,
    this.adaptiveEdgeEnabled = true,
    this.backdropMotion = false,
    this.perimeterOpticsEnabled = true,
    this.edgeTreatment = LiquidGlassEdgeTreatment.perimeter,
  }) : assert(blurSigma >= 0 && blurSigma <= 80),
       assert(intensity >= 0 && intensity <= 2);

  /// Stable key for the bounded [BackdropFilter].
  static const backdropKey = ValueKey<String>('liquid-glass-backdrop');

  /// Stable key for the refractive edge paint layer.
  static const opticsKey = ValueKey<String>('liquid-glass-optics');

  /// Legacy diagnostics key retained for compatibility.
  ///
  /// Refraction is now composed into [backdropKey], so this key is never
  /// mounted and no competing backdrop capture can expose sharp content.
  static const adaptiveEdgeKey = ValueKey<String>('liquid-glass-adaptive-edge');

  /// Stable key for the tint painted above both blur and refraction.
  static const surfaceTintKey = ValueKey<String>('liquid-glass-surface-tint');

  /// Stable key for the shadow cast by the glass sheet.
  static const shadowKey = ValueKey<String>('liquid-glass-shadow');

  /// Starts loading the optional Impeller refraction program ahead of the
  /// first Liquid Glass frame. Unsupported renderers fall back to the same
  /// continuous neutral blur without changing the surface geometry.
  static Future<void> warmUp() async {
    await _LiquidGlassShaderProgram.ensureLoaded();
  }

  final Widget child;
  final BorderRadiusGeometry borderRadius;

  /// Sigma for the backdrop blur. It is always clipped to this surface.
  final double blurSigma;

  /// Scales only neutral optical depth and highlights.
  final double intensity;

  final Clip clipBehavior;

  /// Optional shared input for the full-surface blur.
  ///
  /// Non-overlapping sibling sheets may reuse one [BackdropKey] so the engine
  /// captures their common backdrop only once. Refractive sheets remain
  /// independent because each one carries shape-specific shader uniforms.
  final BackdropKey? backdropGroupKey;

  /// Whether the live color-sampling rim is active.
  ///
  /// The painted highlight, shadow, tint and full backdrop blur remain
  /// unchanged when this is false. It is intended only as a compatibility or
  /// accessibility switch; motion should use [backdropMotion] instead.
  final bool adaptiveEdgeEnabled;

  /// Whether this sheet or the content behind it is currently moving.
  ///
  /// Motion never disables blur or refraction. It only energizes the material
  /// sheen while a capsule is morphing, then lets the highlights settle.
  final bool backdropMotion;

  /// Whether this sheet paints a standalone shadow and refractive perimeter.
  ///
  /// Edge-to-edge chrome such as a pinned tab header is part of the window
  /// rather than a floating capsule. It can disable this while retaining the
  /// exact same backdrop blur and neutral tint, avoiding a rectangular rim at
  /// the viewport edges. Floating surfaces keep this enabled by default.
  final bool perimeterOpticsEnabled;

  /// Shape of the exposed optical edge.
  ///
  /// [perimeterOpticsEnabled] remains as a compatibility switch. When it is
  /// false it overrides this value with [LiquidGlassEdgeTreatment.none].
  final LiquidGlassEdgeTreatment edgeTreatment;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.brightnessOf(context);
    final textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final resolvedEdgeTreatment = perimeterOpticsEnabled
        ? edgeTreatment
        : LiquidGlassEdgeTreatment.none;
    final hasOpticalEdge =
        resolvedEdgeTreatment != LiquidGlassEdgeTreatment.none;
    final isFloatingSheet =
        resolvedEdgeTreatment == LiquidGlassEdgeTreatment.perimeter;
    final resolvedBorderRadius = borderRadius.resolve(textDirection);
    final surfaceTint = brightness == Brightness.dark
        ? const Color(0xFF121212)
        : const Color(0xFFFAFAFA);
    // Echo's default surface opacity is 40%. A dark neutral veil gives the
    // controls contrast without bleaching the refracted backdrop color.
    const baseTintAlpha = 0.4;
    final surfaceTintAlpha =
        (baseTintAlpha * intensity * (highContrast ? 1.16 : 1.0)).clamp(
          0.0,
          0.52,
        );
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final opticalMotionDuration = disableAnimations
        ? Duration.zero
        : backdropMotion
        ? const Duration(milliseconds: 140)
        : const Duration(milliseconds: 420);
    final opticalMotionCurve = backdropMotion
        ? Curves.easeOutCubic
        : Curves.easeOutQuart;

    final clippedSheet = ClipRRect(
      borderRadius: resolvedBorderRadius,
      clipBehavior: clipBehavior,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: _LiquidGlassBackdrop(
              blurSigma: blurSigma,
              backdropGroupKey: backdropGroupKey,
              refractionEnabled: hasOpticalEdge && adaptiveEdgeEnabled,
              treatment: resolvedEdgeTreatment,
              borderRadius: borderRadius,
              textDirection: textDirection,
              intensity: intensity,
              highContrast: highContrast,
            ),
          ),
          // Draw the neutral material tint after blur and refraction. An
          // untinted lens over saturated artwork reads as a plastic ring.
          Positioned.fill(
            child: DecoratedBox(
              key: surfaceTintKey,
              decoration: BoxDecoration(
                color: surfaceTint.withValues(alpha: surfaceTintAlpha),
              ),
            ),
          ),
          RepaintBoundary(child: child),
          if (hasOpticalEdge)
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: backdropMotion ? 1 : 0),
                    duration: opticalMotionDuration,
                    curve: opticalMotionCurve,
                    builder: (context, motion, _) => CustomPaint(
                      key: opticsKey,
                      painter: _LiquidGlassOpticsPainter(
                        borderRadius: borderRadius,
                        treatment: resolvedEdgeTreatment,
                        textDirection: textDirection,
                        brightness: brightness,
                        intensity: intensity,
                        highContrast: highContrast,
                        motion: motion,
                        useCompatibleBlendMode:
                            Theme.of(context).platform ==
                            TargetPlatform.android,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (!isFloatingSheet) {
      return RepaintBoundary(child: clippedSheet);
    }
    return RepaintBoundary(
      child: CustomPaint(
        key: shadowKey,
        painter: _LiquidGlassShadowPainter(
          borderRadius: borderRadius,
          textDirection: textDirection,
          brightness: brightness,
          intensity: intensity,
          highContrast: highContrast,
        ),
        child: clippedSheet,
      ),
    );
  }
}

/// A localized, hover-only glass droplet for one tab or control.
///
/// It intentionally observes only hover-capable pointers. Taps, presses and
/// touch drags never materialize the droplet; their feedback remains the
/// responsibility of the wrapped control.
class LiquidGlassHoverTarget extends StatefulWidget {
  const LiquidGlassHoverTarget({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.enabled = true,
    this.intensity = 1,
  }) : assert(intensity >= 0 && intensity <= 2);

  static const effectKey = ValueKey<String>('liquid-glass-hover-droplet');

  final Widget child;
  final BorderRadiusGeometry borderRadius;
  final bool enabled;
  final double intensity;

  @override
  State<LiquidGlassHoverTarget> createState() => _LiquidGlassHoverTargetState();
}

class _LiquidGlassHoverTargetState extends State<LiquidGlassHoverTarget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _activation;
  late final _LiquidGlassHoverInteraction _interaction;
  final GlobalKey _retainedChildKey = GlobalKey(
    debugLabel: 'liquid-glass-hover-content',
  );
  bool _disableAnimations = false;
  bool _effectMaterialized = false;

  @override
  void initState() {
    super.initState();
    _activation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      reverseDuration: const Duration(milliseconds: 310),
    );
    _interaction = _LiquidGlassHoverInteraction();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_disableAnimations == disableAnimations) {
      return;
    }
    _disableAnimations = disableAnimations;
    if (_disableAnimations) {
      _activation.stop();
      _activation.value = _interaction.hovered ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(LiquidGlassHoverTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _interaction.reset();
      _animate(false);
    }
  }

  @override
  void dispose() {
    _activation.dispose();
    super.dispose();
  }

  bool _supportsHover(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  void _animate(bool visible) {
    final target = visible ? 1.0 : 0.0;
    if (_disableAnimations) {
      _activation.stop();
      _activation.value = target;
      return;
    }
    _activation.animateTo(
      target,
      duration: visible
          ? const Duration(milliseconds: 250)
          : const Duration(milliseconds: 310),
      curve: Curves.easeOutQuart,
    );
  }

  void _handleEnter(PointerEnterEvent event) {
    if (!widget.enabled || !_supportsHover(event.kind)) {
      return;
    }
    if (!_effectMaterialized) {
      setState(() => _effectMaterialized = true);
    }
    _interaction.setHovered(true, pointerKind: event.kind);
    _animate(true);
  }

  void _handleExit(PointerExitEvent event) {
    if (!_interaction.hovered || !_supportsHover(event.kind)) {
      return;
    }
    _interaction.setHovered(false, pointerKind: event.kind);
    _animate(false);
  }

  @override
  Widget build(BuildContext context) {
    final retainedChild = KeyedSubtree(
      key: _retainedChildKey,
      child: widget.child,
    );

    // Touch-only devices never receive a hover enter event. Until a real
    // hover-capable pointer arrives, keep their navigation item as the direct
    // child so Android does not carry an idle Stack, CustomPaint and two extra
    // repaint boundaries for an effect it cannot display.
    Widget content = retainedChild;
    if (_effectMaterialized) {
      final brightness = Theme.brightnessOf(context);
      final textDirection =
          Directionality.maybeOf(context) ?? TextDirection.ltr;
      final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
      content = RepaintBoundary(
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: LiquidGlassHoverTarget.effectKey,
                    painter: LiquidGlassHoverPainter._(
                      interaction: _interaction,
                      activation: _activation,
                      repaint: _activation,
                      borderRadius: widget.borderRadius,
                      textDirection: textDirection,
                      brightness: brightness,
                      intensity: widget.intensity,
                      highContrast: highContrast,
                    ),
                  ),
                ),
              ),
            ),
            retainedChild,
          ],
        ),
      );
    }

    return MouseRegion(
      opaque: false,
      onEnter: _handleEnter,
      onExit: _handleExit,
      child: content,
    );
  }
}

class _LiquidGlassHoverInteraction {
  bool hovered = false;
  PointerDeviceKind pointerKind = PointerDeviceKind.unknown;

  void setHovered(bool value, {required PointerDeviceKind pointerKind}) {
    if (hovered == value && this.pointerKind == pointerKind) {
      return;
    }
    hovered = value;
    this.pointerKind = pointerKind;
  }

  void reset() {
    if (!hovered && pointerKind == PointerDeviceKind.unknown) {
      return;
    }
    hovered = false;
    pointerKind = PointerDeviceKind.unknown;
  }
}

class _LiquidGlassBackdrop extends StatefulWidget {
  const _LiquidGlassBackdrop({
    required this.blurSigma,
    required this.backdropGroupKey,
    required this.refractionEnabled,
    required this.treatment,
    required this.borderRadius,
    required this.textDirection,
    required this.intensity,
    required this.highContrast,
  });

  final double blurSigma;
  final BackdropKey? backdropGroupKey;
  final bool refractionEnabled;
  final LiquidGlassEdgeTreatment treatment;
  final BorderRadiusGeometry borderRadius;
  final TextDirection textDirection;
  final double intensity;
  final bool highContrast;

  @override
  State<_LiquidGlassBackdrop> createState() => _LiquidGlassBackdropState();
}

class _LiquidGlassBackdropState extends State<_LiquidGlassBackdrop> {
  static final Expando<Map<double, ui.ImageFilter>> _groupedBlurFilters =
      Expando<Map<double, ui.ImageFilter>>('liquid-glass-grouped-blurs');
  static const _maximumGroupedSigmaEntries = 8;

  double? _cachedBlurSigma;
  Offset? _cachedSurfaceOriginPx;
  Size? _cachedSurfaceSizePx;
  double? _cachedIntensity;
  BackdropKey? _cachedBackdropGroupKey;
  BorderRadius? _cachedBorderRadius;
  LiquidGlassEdgeTreatment? _cachedTreatment;
  bool? _cachedHighContrast;
  ui.ImageFilter? _cachedBlurFilter;
  ui.ImageFilter? _cachedComposedBlurFilter;
  ui.ImageFilter? _cachedRefractionFilter;
  ui.FragmentProgram? _fragmentProgram;
  ui.FragmentShader? _fragmentShader;
  bool _shaderCreationFailed = false;

  @override
  void initState() {
    super.initState();
    if (!_LiquidGlassShaderProgram.isSupported) {
      return;
    }
    final warmedProgram = _LiquidGlassShaderProgram.program;
    if (warmedProgram != null) {
      _fragmentProgram = warmedProgram;
      return;
    }
    _LiquidGlassShaderProgram.ensureLoaded().then((program) {
      if (!mounted || program == null) {
        return;
      }
      setState(() {
        _fragmentProgram = program;
        _cachedRefractionFilter = null;
      });
    });
  }

  @override
  void dispose() {
    _fragmentShader?.dispose();
    super.dispose();
  }

  ui.ImageFilter _blurFilterForGroup(BackdropKey? groupKey) {
    if (_cachedBlurFilter == null ||
        _cachedBlurSigma != widget.blurSigma ||
        _cachedBackdropGroupKey != groupKey) {
      _cachedBlurSigma = widget.blurSigma;
      _cachedBackdropGroupKey = groupKey;
      _cachedBlurFilter = _sharedBlurFilterFor(
        sigma: widget.blurSigma,
        groupKey: groupKey,
      );
    }
    return _cachedBlurFilter!;
  }

  bool get _usesRefraction =>
      widget.refractionEnabled &&
      widget.treatment != LiquidGlassEdgeTreatment.none &&
      _fragmentProgram != null &&
      !_shaderCreationFailed &&
      _LiquidGlassShaderProgram.isSupported;

  ui.ImageFilter _materialFilter({
    required Rect surfaceBoundsPx,
    required double devicePixelRatio,
    required BorderRadius borderRadius,
    required BackdropKey? groupKey,
  }) {
    final blur = _blurFilterForGroup(groupKey);
    if (!_usesRefraction) {
      return blur;
    }
    // ImageFilter.shader receives coordinates in the backdrop texture's
    // coordinate space. On a full-window capture that means a small search orb
    // near the right edge starts around x=1100 instead of x=0. Preserve both
    // the physical origin and size so the shader can build its SDF locally.
    final surfaceOriginPx = surfaceBoundsPx.topLeft;
    final surfaceSizePx = surfaceBoundsPx.size;
    final opticalDimension = surfaceSizePx.shortestSide / devicePixelRatio;
    if (_cachedRefractionFilter == null ||
        _cachedComposedBlurFilter != blur ||
        _cachedSurfaceOriginPx != surfaceOriginPx ||
        _cachedSurfaceSizePx != surfaceSizePx ||
        _cachedIntensity != widget.intensity ||
        _cachedBorderRadius != borderRadius ||
        _cachedTreatment != widget.treatment ||
        _cachedHighContrast != widget.highContrast) {
      _cachedSurfaceOriginPx = surfaceOriginPx;
      _cachedSurfaceSizePx = surfaceSizePx;
      _cachedComposedBlurFilter = blur;
      _cachedIntensity = widget.intensity;
      _cachedBorderRadius = borderRadius;
      _cachedTreatment = widget.treatment;
      _cachedHighContrast = widget.highContrast;
      try {
        final shader = _fragmentShader ??= _fragmentProgram!.fragmentShader();
        final minimumDimension = math.max(1.0, opticalDimension);
        final opticalStrength = widget.intensity.clamp(0.72, 1.28);
        final embedded = widget.treatment == LiquidGlassEdgeTreatment.bottom;
        // A shallow 8dp band only reads as a blurred outline on a 56-72dp
        // capsule. Keep a visibly convex shoulder while reserving a broad,
        // calm centre so bright cover art cannot turn the whole sheet milky.
        final refractionHeight = embedded
            ? 8.0 * opticalStrength
            : (opticalDimension * (widget.highContrast ? 0.28 : 0.25)).clamp(
                    12.0,
                    18.0,
                  ) *
                  opticalStrength;
        final refractionAmount = embedded
            ? 6.0 * opticalStrength
            : (opticalDimension * 0.34).clamp(16.0, 24.0) * opticalStrength;
        double radiusRatio(Radius radius) =>
            (math.min(radius.x, radius.y) / minimumDimension).clamp(0.0, 0.5);

        // Slots 0-1 are populated by ImageFilter.shader with the backing
        // texture size. The following slots preserve this widget's physical
        // dimensions and its origin inside that backing texture.
        shader
          ..setFloat(2, surfaceSizePx.width)
          ..setFloat(3, surfaceSizePx.height)
          ..setFloat(4, surfaceOriginPx.dx)
          ..setFloat(5, surfaceOriginPx.dy)
          ..setFloat(6, (refractionHeight / minimumDimension).clamp(0.0, 0.5))
          ..setFloat(7, (refractionAmount / minimumDimension).clamp(0.0, 0.5))
          // The reference shader treats depth as a real on/off term (1.0).
          // Keep it slightly below that maximum so stretched Flutter pills
          // bulge without pulling their end caps into a fisheye.
          ..setFloat(8, embedded ? 0 : (widget.highContrast ? 0.92 : 0.82))
          // Dispersion stays deliberately restrained: the edge should inherit
          // the artwork hue, not turn into a detached rainbow fringe.
          ..setFloat(9, embedded ? 0 : 0.055)
          ..setFloat(10, radiusRatio(borderRadius.topLeft))
          ..setFloat(11, radiusRatio(borderRadius.topRight))
          ..setFloat(12, radiusRatio(borderRadius.bottomRight))
          ..setFloat(13, radiusRatio(borderRadius.bottomLeft))
          ..setFloat(14, (1 + 0.3 * widget.intensity).clamp(1.0, 1.44))
          ..setFloat(15, (1 + 0.42 * widget.intensity).clamp(1.0, 1.5))
          ..setFloat(16, embedded ? 1 : 0);
        final lens = ui.ImageFilter.shader(shader);
        _cachedRefractionFilter = ui.ImageFilter.compose(
          inner: blur,
          outer: lens,
        );
      } on Object {
        _shaderCreationFailed = true;
        _cachedRefractionFilter = null;
      }
    }
    return _cachedRefractionFilter ?? blur;
  }

  Rect _surfaceBoundsInPhysicalPixels({
    required Size fallbackSize,
    required double devicePixelRatio,
  }) {
    Rect logicalBounds = Offset.zero & fallbackSize;
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox &&
        renderObject.attached &&
        renderObject.hasSize) {
      logicalBounds = MatrixUtils.transformRect(
        renderObject.getTransformTo(null),
        Offset.zero & renderObject.size,
      );
    }
    double physical(double value) =>
        (value * devicePixelRatio * 2).roundToDouble() / 2;
    return Rect.fromLTRB(
      physical(logicalBounds.left),
      physical(logicalBounds.top),
      physical(logicalBounds.right),
      physical(logicalBounds.bottom),
    );
  }

  static ui.ImageFilter _sharedBlurFilterFor({
    required double sigma,
    required BackdropKey? groupKey,
  }) {
    ui.ImageFilter create() => ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: TileMode.clamp,
    );
    if (groupKey == null) {
      return create();
    }

    final filters = _groupedBlurFilters[groupKey] ??=
        <double, ui.ImageFilter>{};
    final existing = filters[sigma];
    if (existing != null) {
      return existing;
    }
    if (filters.length >= _maximumGroupedSigmaEntries) {
      filters.remove(filters.keys.first);
    }
    return filters[sigma] = create();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.blurSigma <= 0) {
      return const KeyedSubtree(
        key: LiquidGlassSurface.backdropKey,
        child: SizedBox.expand(),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!size.isFinite || size.isEmpty) {
          return const SizedBox.shrink();
        }
        final borderRadius = widget.borderRadius.resolve(widget.textDirection);
        // Grouping is safe for identical blur-only sheets. A runtime lens has
        // size- and shape-specific uniforms, so reusing a grouped backdrop can
        // make Impeller evaluate that geometry in another surface's bounds.
        final effectiveBackdropGroupKey = _usesRefraction
            ? null
            : widget.backdropGroupKey;
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        final positionAwareFilter = _usesRefraction
            ? _LiquidGlassImageFilterConfig(
                resolver: (_) => _materialFilter(
                  surfaceBoundsPx: _surfaceBoundsInPhysicalPixels(
                    fallbackSize: size,
                    devicePixelRatio: devicePixelRatio,
                  ),
                  devicePixelRatio: devicePixelRatio,
                  borderRadius: borderRadius,
                  groupKey: effectiveBackdropGroupKey,
                ),
              )
            : null;
        return BackdropFilter(
          key: LiquidGlassSurface.backdropKey,
          filter: positionAwareFilter == null
              ? _blurFilterForGroup(effectiveBackdropGroupKey)
              : null,
          filterConfig: positionAwareFilter,
          backdropGroupKey: effectiveBackdropGroupKey,
          blendMode: BlendMode.srcOver,
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

@immutable
class _LiquidGlassImageFilterConfig implements ImageFilterConfig {
  const _LiquidGlassImageFilterConfig({required this.resolver});

  final ui.ImageFilter Function(ImageFilterContext context) resolver;

  @override
  ui.ImageFilter resolve(ImageFilterContext context) => resolver(context);

  @override
  ui.ImageFilter? get filter => null;

  @override
  String get debugShortDescription => 'position-aware liquid-glass lens';

  @override
  bool operator ==(Object other) =>
      other is _LiquidGlassImageFilterConfig && other.resolver == resolver;

  @override
  int get hashCode => resolver.hashCode;
}

class _LiquidGlassShaderProgram {
  static Future<ui.FragmentProgram?>? _load;
  static ui.FragmentProgram? program;

  // The lens is composed with blur inside one BackdropFilter, avoiding the
  // competing live captures that made the previous Android path unstable.
  static bool get isSupported => ui.ImageFilter.isShaderFilterSupported;

  static Future<ui.FragmentProgram?> ensureLoaded() {
    if (!isSupported) {
      return Future<ui.FragmentProgram?>.value(null);
    }
    final loaded = program;
    if (loaded != null) {
      return Future<ui.FragmentProgram?>.value(loaded);
    }
    return _load ??= _loadProgram();
  }

  static Future<ui.FragmentProgram?> _loadProgram() async {
    try {
      final loaded = await ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass_refraction.frag',
      );
      program = loaded;
      return loaded;
    } on Object {
      // Runtime shaders are an enhancement. Unsupported or failed graphics
      // backends continue through the deterministic matrix fallback.
      return null;
    }
  }
}

class _LiquidGlassShadowPainter extends CustomPainter {
  const _LiquidGlassShadowPainter({
    required this.borderRadius,
    required this.textDirection,
    required this.brightness,
    required this.intensity,
    required this.highContrast,
  });

  final BorderRadiusGeometry borderRadius;
  final TextDirection textDirection;
  final Brightness brightness;
  final double intensity;
  final bool highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || intensity == 0) {
      return;
    }
    final bounds = Offset.zero & size;
    final shape = borderRadius.resolve(textDirection).toRRect(bounds);
    final contrastBoost = highContrast ? 1.15 : 1.0;
    final dark = brightness == Brightness.dark;
    // A broad ambient shadow separates the sheet from busy artwork.
    canvas.drawRRect(
      shape.shift(const Offset(0, 4)),
      Paint()
        ..color = Colors.black.withValues(
          alpha: ((dark ? 0.12 : 0.09) * intensity * contrastBoost).clamp(
            0.0,
            0.18,
          ),
        )
        // Android's 24dp BlurMaskFilter maps closely to a 14dp Gaussian sigma.
        // BlurStyle.outer performs the same center cut-out used by backdrop.
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 14),
    );
    // A compact contact shadow is the missing depth cue when an ancestor clips
    // most of the ambient halo (for example, the mobile bottom shell).
    canvas.drawRRect(
      shape.shift(const Offset(0, 1.4)),
      Paint()
        ..color = Colors.black.withValues(
          alpha: ((dark ? 0.19 : 0.13) * intensity * contrastBoost).clamp(
            0.0,
            0.28,
          ),
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 3.4),
    );
  }

  @override
  bool shouldRepaint(_LiquidGlassShadowPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.brightness != brightness ||
      oldDelegate.intensity != intensity ||
      oldDelegate.highContrast != highContrast;
}

class _LiquidGlassOpticsPainter extends CustomPainter {
  const _LiquidGlassOpticsPainter({
    required this.borderRadius,
    required this.treatment,
    required this.textDirection,
    required this.brightness,
    required this.intensity,
    required this.highContrast,
    required this.motion,
    required this.useCompatibleBlendMode,
  });

  final BorderRadiusGeometry borderRadius;
  final LiquidGlassEdgeTreatment treatment;
  final TextDirection textDirection;
  final Brightness brightness;
  final double intensity;
  final bool highContrast;
  final double motion;
  final bool useCompatibleBlendMode;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || intensity == 0) {
      return;
    }
    final contrastBoost = highContrast ? 1.12 : 1.0;
    // Move a colour-preserving sheen over the lens while its geometry changes.
    // This is paint-only, so it does not add another backdrop capture.
    final opticalEnergy = intensity * contrastBoost * (1 + 0.12 * motion);
    final opticalBlendMode = useCompatibleBlendMode
        ? BlendMode.srcOver
        : BlendMode.softLight;
    double alpha(double value, [double maximum = 0.7]) =>
        (value * opticalEnergy).clamp(0.0, maximum);

    if (treatment == LiquidGlassEdgeTreatment.bottom) {
      final seamY = math.max(0.0, size.height - 0.5);
      canvas.drawLine(
        Offset(0, math.max(0.0, seamY - 1.1)),
        Offset(size.width, math.max(0.0, seamY - 1.1)),
        Paint()
          ..strokeWidth = highContrast ? 1.8 : 1.4
          ..blendMode = opticalBlendMode
          ..color = Colors.black.withValues(alpha: alpha(0.16, 0.24))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8),
      );
      canvas.drawLine(
        Offset(0, seamY),
        Offset(size.width, seamY),
        Paint()
          ..strokeWidth = highContrast ? 1.1 : 0.8
          ..blendMode = opticalBlendMode
          ..color = Colors.white.withValues(alpha: alpha(0.58))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.25),
      );
      return;
    }
    if (treatment == LiquidGlassEdgeTreatment.none) {
      return;
    }

    final bounds = Offset.zero & size;
    final resolvedRadius = borderRadius.resolve(textDirection);
    final shape = resolvedRadius.toRRect(bounds);
    final dark = brightness == Brightness.dark;
    final horizontalLightShift = ui.lerpDouble(-0.9, -0.68, motion)!;

    // A very low-energy face gradient gives the clear centre a curved surface
    // even on renderers that cannot run the runtime refraction shader. Using
    // softLight changes the luminance of the sampled backdrop without laying a
    // white film over its hue.
    canvas.drawRRect(
      shape,
      Paint()
        ..blendMode = opticalBlendMode
        ..shader = LinearGradient(
          begin: Alignment(horizontalLightShift, -1),
          end: const Alignment(0.82, 1),
          colors: [
            Colors.white.withValues(
              alpha: alpha(dark ? 0.09 : 0.15, dark ? 0.16 : 0.22),
            ),
            Colors.white.withValues(alpha: alpha(0.025, 0.05)),
            Colors.black.withValues(alpha: alpha(dark ? 0.07 : 0.045, 0.1)),
            Colors.white.withValues(alpha: alpha(dark ? 0.045 : 0.07, 0.11)),
          ],
          stops: const [0, 0.26, 0.72, 1],
        ).createShader(bounds),
    );

    // The outer keyline behaves like Echo's directional highlight. Soft-light
    // makes blue, amber and red backdrops produce blue, amber and red light;
    // it never replaces them with a chalk-white outline.
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = highContrast ? 1.35 : 0.9
        ..blendMode = opticalBlendMode
        ..shader = LinearGradient(
          begin: Alignment(horizontalLightShift, -1),
          end: const Alignment(0.9, 1),
          colors: [
            Colors.white.withValues(alpha: alpha(0.52, 0.68)),
            Colors.white.withValues(alpha: alpha(0.1, 0.16)),
            Colors.white.withValues(alpha: alpha(0.34, 0.5)),
          ],
          stops: const [0, 0.52, 1],
        ).createShader(bounds),
    );

    // A recessed inner contour establishes the thickness between the luminous
    // outer lip and the undistorted centre of the glass.
    final innerBounds = bounds.deflate(highContrast ? 1.8 : 1.45);
    if (!innerBounds.isEmpty) {
      canvas.drawRRect(
        resolvedRadius.toRRect(innerBounds),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = highContrast ? 1.15 : 0.8
          ..blendMode = opticalBlendMode
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.black.withValues(alpha: alpha(dark ? 0.18 : 0.12, 0.24)),
              Colors.transparent,
              Colors.black.withValues(alpha: alpha(dark ? 0.13 : 0.09, 0.19)),
            ],
            stops: const [0, 0.48, 1],
          ).createShader(innerBounds),
      );
    }
  }

  @override
  bool shouldRepaint(_LiquidGlassOpticsPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.treatment != treatment ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.brightness != brightness ||
      oldDelegate.intensity != intensity ||
      oldDelegate.highContrast != highContrast ||
      oldDelegate.motion != motion ||
      oldDelegate.useCompatibleBlendMode != useCompatibleBlendMode;
}

/// Painter exposed for focused hover and performance tests.
class LiquidGlassHoverPainter extends CustomPainter {
  LiquidGlassHoverPainter._({
    required this._interaction,
    required this.activation,
    required Listenable repaint,
    required this.borderRadius,
    required this.textDirection,
    required this.brightness,
    required this.intensity,
    required this.highContrast,
  }) : super(repaint: repaint);

  final _LiquidGlassHoverInteraction _interaction;
  final Animation<double> activation;
  final BorderRadiusGeometry borderRadius;
  final TextDirection textDirection;
  final Brightness brightness;
  final double intensity;
  final bool highContrast;

  @visibleForTesting
  double get visibility => activation.value;

  @visibleForTesting
  bool get isHovered => _interaction.hovered;

  @visibleForTesting
  PointerDeviceKind get pointerKind => _interaction.pointerKind;

  @visibleForTesting
  AnimationStatus get animationStatus => activation.status;

  double get _strength {
    final reveal = Curves.easeOutCubic.transform(
      activation.value.clamp(0.0, 1.0),
    );
    return reveal * intensity * (highContrast ? 1.35 : 1.0);
  }

  @visibleForTesting
  Color get debugShadowColor {
    final dark = brightness == Brightness.dark;
    return Colors.black.withValues(
      alpha: ((dark ? 0.1 : 0.075) * _strength).clamp(0.0, 0.24),
    );
  }

  @visibleForTesting
  List<Color> get debugFillGradientColors {
    final dark = brightness == Brightness.dark;
    final strength = _strength;
    return dark
        ? [
            Colors.white.withValues(alpha: (0.028 * strength).clamp(0.0, 0.08)),
            Colors.transparent,
            Colors.black.withValues(alpha: (0.065 * strength).clamp(0.0, 0.14)),
          ]
        : [
            Colors.white.withValues(alpha: (0.11 * strength).clamp(0.0, 0.22)),
            Colors.transparent,
            Colors.black.withValues(alpha: (0.045 * strength).clamp(0.0, 0.1)),
          ];
  }

  @visibleForTesting
  List<Color> get debugRimGradientColors {
    final dark = brightness == Brightness.dark;
    final strength = _strength;
    return [
      Colors.white.withValues(
        alpha: ((dark ? 0.22 : 0.28) * strength).clamp(0.0, 0.48),
      ),
      Colors.white.withValues(
        alpha: ((dark ? 0.035 : 0.05) * strength).clamp(0.0, 0.12),
      ),
      Colors.white.withValues(
        alpha: ((dark ? 0.13 : 0.16) * strength).clamp(0.0, 0.32),
      ),
    ];
  }

  @visibleForTesting
  Color get debugInnerRimColor {
    final dark = brightness == Brightness.dark;
    return Colors.black.withValues(
      alpha: ((dark ? 0.1 : 0.065) * _strength).clamp(0.0, 0.2),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rawVisibility = activation.value.clamp(0.0, 1.0);
    if (rawVisibility <= 0.001 || size.isEmpty) {
      return;
    }
    final reveal = Curves.easeOutCubic.transform(rawVisibility);
    final horizontalInset = ui.lerpDouble(size.width * 0.025, 0.75, reveal)!;
    final verticalInset = ui.lerpDouble(size.height * 0.06, 0.75, reveal)!;
    final bounds = Rect.fromLTRB(
      horizontalInset,
      verticalInset,
      size.width - horizontalInset,
      size.height - verticalInset,
    );
    if (bounds.isEmpty) {
      return;
    }
    final resolvedRadius = borderRadius.resolve(textDirection);
    final shape = resolvedRadius.toRSuperellipse(bounds);
    final shadowBounds = bounds.shift(const Offset(0, 1.2));

    canvas.drawRSuperellipse(
      resolvedRadius.toRSuperellipse(shadowBounds),
      Paint()
        ..color = debugShadowColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 4.2),
    );
    canvas.drawRSuperellipse(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: debugFillGradientColors,
        ).createShader(bounds),
    );
    canvas.drawRSuperellipse(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = highContrast ? 1.3 : 0.85
        // Soft light changes luminance without replacing the hue already
        // present in the parent glass, unlike a white srcOver outline.
        ..blendMode = BlendMode.softLight
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: debugRimGradientColors,
          stops: const [0, 0.52, 1],
        ).createShader(bounds),
    );
    final innerBounds = bounds.deflate(1.8);
    if (!innerBounds.isEmpty) {
      canvas.drawRSuperellipse(
        resolvedRadius.toRSuperellipse(innerBounds),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7
          ..color = debugInnerRimColor,
      );
    }
  }

  @override
  bool shouldRepaint(LiquidGlassHoverPainter oldDelegate) =>
      oldDelegate._interaction != _interaction ||
      oldDelegate.activation != activation ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.brightness != brightness ||
      oldDelegate.intensity != intensity ||
      oldDelegate.highContrast != highContrast;
}
