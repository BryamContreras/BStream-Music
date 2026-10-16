import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
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

/// Shares scroll activity with glass nested in pinned inputs and headings.
/// The inherited value is the listenable itself, so scroll start/end only
/// rebuilds the small surfaces listening to it, not the scrolling body.
class LiquidGlassMotionScope extends InheritedWidget {
  const LiquidGlassMotionScope({
    required this.motion,
    required super.child,
    super.key,
  });

  final ValueListenable<bool> motion;

  static ValueListenable<bool>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LiquidGlassMotionScope>()
      ?.motion;

  @override
  bool updateShouldNotify(LiquidGlassMotionScope oldWidget) =>
      motion != oldWidget.motion;
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
    this.backdropEnvelope,
    this.shadowClipInsets,
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

  /// Exercises the native backdrop-layer topology without requiring a runtime
  /// shader in widget tests. Production surfaces select this host on Windows
  /// only, after the real refractive shader has loaded successfully.
  @visibleForTesting
  static Widget debugBackdropLayerHost({
    required double devicePixelRatio,
    required Size viewportSize,
    required ui.ImageFilter blurFilter,
    required ui.ImageFilter Function(Rect bounds, bool bounded) resolveMaterial,
    bool Function()? materialIsRefractive,
    BackdropKey? backdropGroupKey,
    Widget child = const SizedBox.expand(),
  }) => _LiquidGlassBackdropLayerHost(
    devicePixelRatio: devicePixelRatio,
    viewportSize: viewportSize,
    blurFilter: blurFilter,
    resolveMaterial: resolveMaterial,
    materialIsRefractive: materialIsRefractive,
    backdropGroupKey: backdropGroupKey,
    child: child,
  );

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
  /// captures their common backdrop only once. Each refractive sheet retains
  /// its own lens: the engine shares filtered output only for equal filters,
  /// including their shader uniforms. Never group overlapping sheets.
  final BackdropKey? backdropGroupKey;

  /// Optional fixed backdrop extent, relative to the real lens bounds.
  ///
  /// A containing rectangle (including negative offsets) can retain the same
  /// backing size while a capsule morphs. Only translation-only, tightly sized
  /// circular-corner lenses on shader-capable renderers opt in; all other
  /// configurations retain the original native rounded-rectangle clip.
  final Rect? backdropEnvelope;

  /// Optional original shell margins to retain its exterior shadow crop when
  /// a fixed [backdropEnvelope] extends beyond that shell's horizontal bounds.
  /// This clips only the shadow, never the backdrop or the actual surface.
  final EdgeInsets? shadowClipInsets;

  /// Whether the live color-sampling rim is active.
  ///
  /// The painted highlight, shadow, tint and full backdrop blur remain
  /// unchanged when this is false. It is intended only as a compatibility or
  /// accessibility switch, not as a lower-quality scrolling mode.
  final bool adaptiveEdgeEnabled;

  /// Whether this sheet or the content behind it is currently moving.
  ///
  /// Motion animates the painted highlight without reducing the blur or
  /// disabling refraction. The complete material remains live during scroll
  /// and geometry transitions on mobile as well as desktop.
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
    if (backdropEnvelope != null &&
        _LiquidGlassShaderProgram.isSupported &&
        blurSigma > 0 &&
        adaptiveEdgeEnabled &&
        perimeterOpticsEnabled &&
        edgeTreatment == LiquidGlassEdgeTreatment.perimeter &&
        clipBehavior == Clip.antiAlias) {
      return _LiquidGlassEnvelopeGate(surface: this);
    }
    return _buildSheet(context);
  }

  Widget _buildSheet(
    BuildContext context, {
    Rect? envelope,
    Size? lensSize,
    ui.FragmentShader? preparedShader,
    VoidCallback? onEnvelopeFailure,
  }) {
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
    final foreground = <Widget>[
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
                    // Impeller's Windows OpenGL backend can replay a
                    // soft-light paint against the complete backing
                    // surface when an overlaid control repaints (for
                    // example, when the mini player receives hover).
                    // Src-over keeps the optics bounded to this sheet.
                    useCompatibleBlendMode: switch (Theme.of(
                      context,
                    ).platform) {
                      TargetPlatform.android || TargetPlatform.windows => true,
                      _ => false,
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
    final boundDesktopForeground =
        envelope == null &&
        _LiquidGlassShaderProgram.isSupported &&
        Theme.of(context).platform == TargetPlatform.windows;
    final backdrop = _LiquidGlassBackdrop(
      blurSigma: blurSigma,
      backdropGroupKey: backdropGroupKey,
      refractionEnabled: hasOpticalEdge && adaptiveEdgeEnabled,
      treatment: resolvedEdgeTreatment,
      borderRadius: borderRadius,
      textDirection: textDirection,
      intensity: intensity,
      highContrast: highContrast,
      lensBounds: envelope == null ? null : -envelope.topLeft & lensSize!,
      preparedShader: preparedShader,
      onEnvelopeFailure: onEnvelopeFailure,
      // Advanced blends in the seam and hover glints must see the same
      // blurred/tinted background, but not force a full-window backdrop copy.
      // Keeping the exact foreground inside the material's bounded native
      // target preserves those effects without changing their paint recipe.
      child: boundDesktopForeground
          ? Stack(fit: StackFit.passthrough, children: foreground)
          : null,
    );
    final clippedSheet = ClipRRect(
      borderRadius: resolvedBorderRadius,
      clipBehavior: clipBehavior,
      child: boundDesktopForeground
          ? backdrop
          : Stack(
              fit: StackFit.passthrough,
              children: [
                if (envelope == null) Positioned.fill(child: backdrop),
                ...foreground,
              ],
            ),
    );
    final sheet = envelope == null
        ? clippedSheet
        : Stack(
            fit: StackFit.passthrough,
            clipBehavior: Clip.none,
            children: [
              Positioned.fromRect(
                rect: envelope,
                child: IgnorePointer(child: ClipRect(child: backdrop)),
              ),
              clippedSheet,
            ],
          );
    if (!isFloatingSheet) {
      return RepaintBoundary(child: sheet);
    }
    final shadow = RepaintBoundary(
      child: CustomPaint(
        key: shadowKey,
        isComplex: true,
        painter: _LiquidGlassShadowPainter(
          borderRadius: borderRadius,
          textDirection: textDirection,
          brightness: brightness,
          intensity: intensity,
          highContrast: highContrast,
        ),
      ),
    );
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          // A backdrop changes every time content scrolls behind it. Keeping
          // the two Gaussian shadows in that same layer makes the GPU blur
          // their masks repeatedly even when the glass bounds are unchanged.
          // An independent, cacheable paint layer keeps the exact shadow
          // recipe while the live backdrop continues below the controls.
          Positioned.fill(
            child: IgnorePointer(
              child: shadowClipInsets == null
                  ? shadow
                  : ClipRect(
                      clipper: _LiquidGlassShadowClipper(shadowClipInsets!),
                      child: shadow,
                    ),
            ),
          ),
          sheet,
        ],
      ),
    );
  }
}

class _LiquidGlassShadowClipper extends CustomClipper<Rect> {
  const _LiquidGlassShadowClipper(this.insets);

  final EdgeInsets insets;

  @override
  Rect getClip(Size size) => insets.inflateRect(Offset.zero & size);

  @override
  bool shouldReclip(_LiquidGlassShadowClipper oldClipper) =>
      insets != oldClipper.insets;
}

/// Owns a preflighted shader before relaxing the native lens clip. Failure
/// always restores that clip; an expanded, unmasked blur is never painted.
class _LiquidGlassEnvelopeGate extends StatefulWidget {
  const _LiquidGlassEnvelopeGate({required this.surface});

  final LiquidGlassSurface surface;

  @override
  State<_LiquidGlassEnvelopeGate> createState() =>
      _LiquidGlassEnvelopeGateState();
}

class _LiquidGlassEnvelopeGateState extends State<_LiquidGlassEnvelopeGate> {
  ui.FragmentShader? _shader;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final program = _LiquidGlassShaderProgram.program;
    if (program != null) {
      _prepare(program);
    } else {
      _LiquidGlassShaderProgram.ensureLoaded().then((program) {
        if (!mounted || program == null) return;
        setState(() => _prepare(program));
      });
    }
  }

  void _prepare(ui.FragmentProgram program) {
    ui.FragmentShader? shader;
    try {
      shader = program.fragmentShader();
      shader.setFloat(17, 1);
      ui.ImageFilter.shader(shader);
      _shader = shader;
    } on Object {
      shader?.dispose();
      _failed = true;
    }
  }

  void _failSafely() {
    if (_failed) return;
    _failed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final surface = widget.surface;
      final envelope = surface.backdropEnvelope!;
      final size = constraints.biggest;
      final radius = surface.borderRadius.resolve(Directionality.of(context));
      var eligible =
          !_failed &&
          _shader != null &&
          constraints.isTight &&
          size.isFinite &&
          !size.isEmpty &&
          envelope.isFinite &&
          envelope.left <= 0 &&
          envelope.top <= 0 &&
          envelope.right >= size.width &&
          envelope.bottom >= size.height &&
          radius.topLeft.x == radius.topLeft.y &&
          radius.topLeft == radius.topRight &&
          radius.topLeft == radius.bottomLeft &&
          radius.topLeft == radius.bottomRight;
      if (eligible) {
        try {
          final box = context.findRenderObject();
          eligible =
              box is RenderBox &&
              box.attached &&
              MatrixUtils.getAsTranslation(box.getTransformTo(null)) != null;
        } on Object {
          eligible = false;
        }
      }
      return surface._buildSheet(
        context,
        envelope: eligible ? envelope : null,
        lensSize: eligible ? size : null,
        preparedShader: eligible ? _shader : null,
        onEnvelopeFailure: eligible ? _failSafely : null,
      );
    },
  );
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
    this.lensBounds,
    this.preparedShader,
    this.onEnvelopeFailure,
    this.child,
  });

  final double blurSigma;
  final BackdropKey? backdropGroupKey;
  final bool refractionEnabled;
  final LiquidGlassEdgeTreatment treatment;
  final BorderRadiusGeometry borderRadius;
  final TextDirection textDirection;
  final double intensity;
  final bool highContrast;
  final Rect? lensBounds;
  final ui.FragmentShader? preparedShader;
  final VoidCallback? onEnvelopeFailure;
  final Widget? child;

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
  ui.FragmentShader? _cachedPreparedShader;
  bool? _cachedShapeMask;
  bool? _cachedBoundedBackdrop;
  ui.ImageFilter? _cachedBlurFilter;
  ui.ImageFilter? _cachedComposedBlurFilter;
  ui.ImageFilter? _cachedRefractionFilter;
  ui.FragmentProgram? _fragmentProgram;
  ui.FragmentShader? _fragmentShader;
  bool _shaderCreationFailed = false;
  Object? _filterConfigSignature;
  ImageFilterConfig? _positionAwareFilterConfig;
  _LiquidGlassMaterialResolver? _desktopMaterialResolver;

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
      (_fragmentProgram != null || widget.preparedShader != null) &&
      !_shaderCreationFailed &&
      _LiquidGlassShaderProgram.isSupported;

  ui.ImageFilter _materialFilter({
    required Rect surfaceBoundsPx,
    required double devicePixelRatio,
    required BorderRadius borderRadius,
    required BackdropKey? groupKey,
    bool boundedBackdrop = false,
  }) {
    final blur = _blurFilterForGroup(groupKey);
    if (!_usesRefraction) {
      return widget.lensBounds == null ? blur : _envelopeFailureFilter();
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
        _cachedHighContrast != widget.highContrast ||
        _cachedPreparedShader != widget.preparedShader ||
        _cachedShapeMask != (widget.lensBounds != null) ||
        _cachedBoundedBackdrop != boundedBackdrop) {
      _cachedSurfaceOriginPx = surfaceOriginPx;
      _cachedSurfaceSizePx = surfaceSizePx;
      _cachedComposedBlurFilter = blur;
      _cachedIntensity = widget.intensity;
      _cachedBorderRadius = borderRadius;
      _cachedTreatment = widget.treatment;
      _cachedHighContrast = widget.highContrast;
      _cachedPreparedShader = widget.preparedShader;
      _cachedShapeMask = widget.lensBounds != null;
      _cachedBoundedBackdrop = boundedBackdrop;
      try {
        final shader =
            widget.preparedShader ??
            (_fragmentShader ??= _fragmentProgram!.fragmentShader());
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
          ..setFloat(16, embedded ? 1 : 0)
          ..setFloat(17, widget.lensBounds == null ? 0 : 1);
        final lens = ui.ImageFilter.shader(shader);
        _cachedRefractionFilter = boundedBackdrop
            ? lens
            : ui.ImageFilter.compose(inner: blur, outer: lens);
      } on Object {
        _shaderCreationFailed = true;
        _cachedRefractionFilter = null;
        if (widget.lensBounds != null) return _envelopeFailureFilter();
      }
    }
    return _cachedRefractionFilter ?? blur;
  }

  ui.ImageFilter _envelopeFailureFilter() {
    _shaderCreationFailed = true;
    widget.onEnvelopeFailure?.call();
    return const ui.ColorFilter.mode(Color(0x00000000), BlendMode.src);
  }

  Rect _surfaceBoundsInPhysicalPixels({
    required Size fallbackSize,
    required double devicePixelRatio,
    bool roundBounds = true,
  }) {
    Rect logicalBounds = widget.lensBounds ?? (Offset.zero & fallbackSize);
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox &&
        renderObject.attached &&
        renderObject.hasSize) {
      final transform = renderObject.getTransformTo(null);
      if (widget.lensBounds != null &&
          MatrixUtils.getAsTranslation(transform) == null) {
        // A paint-only ancestor scale can bypass layout eligibility. Do not
        // expose an unmasked expanded blur while restoring the native clip.
        _envelopeFailureFilter();
      }
      logicalBounds = MatrixUtils.transformRect(
        transform,
        widget.lensBounds ?? (Offset.zero & renderObject.size),
      );
    }
    double physical(double value) => roundBounds
        ? (value * devicePixelRatio * 2).roundToDouble() / 2
        : value * devicePixelRatio;
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

  bool _materialIsRefractive() => _usesRefraction;

  Widget _buildDesktopForeground(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final radius = widget.borderRadius.resolve(widget.textDirection);
    final signature = (
      devicePixelRatio,
      radius,
      widget.blurSigma,
      widget.intensity,
      widget.treatment,
      widget.highContrast,
      widget.backdropGroupKey,
      _fragmentProgram,
      widget.preparedShader,
    );
    if (signature != _filterConfigSignature) {
      _filterConfigSignature = signature;
      _desktopMaterialResolver = (bounds, bounded) => _materialFilter(
        surfaceBoundsPx: bounds,
        devicePixelRatio: devicePixelRatio,
        borderRadius: radius,
        groupKey: bounded ? null : widget.backdropGroupKey,
        boundedBackdrop: bounded,
      );
    }
    // No LayoutBuilder: a menu's IntrinsicWidth must be able to measure its
    // real foreground. The render proxy delegates intrinsic sizes normally,
    // then resolves physical lens geometry only after layout has completed.
    return KeyedSubtree(
      key: LiquidGlassSurface.backdropKey,
      child: _LiquidGlassBackdropLayerHost(
        devicePixelRatio: devicePixelRatio,
        viewportSize: MediaQuery.sizeOf(context),
        blurFilter: _blurFilterForGroup(null),
        backdropGroupKey: widget.backdropGroupKey,
        resolveMaterial: _desktopMaterialResolver!,
        materialIsRefractive: _materialIsRefractive,
        child: widget.child!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.blurSigma <= 0) {
      return KeyedSubtree(
        key: LiquidGlassSurface.backdropKey,
        child: widget.child ?? const SizedBox.expand(),
      );
    }
    if (widget.child != null &&
        widget.lensBounds == null &&
        Theme.of(context).platform == TargetPlatform.windows) {
      return _buildDesktopForeground(context);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!size.isFinite || size.isEmpty) {
          return const SizedBox.shrink();
        }
        final borderRadius = widget.borderRadius.resolve(widget.textDirection);
        // Non-overlapping siblings can share the original backdrop capture.
        // Impeller compares the complete filter (including lens uniforms)
        // before reusing any processed output, so distinct shapes keep their
        // own refraction. The mini player deliberately uses a separate key.
        final effectiveBackdropGroupKey = widget.backdropGroupKey;
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        final useDesktopLayerHost =
            _usesRefraction &&
            widget.lensBounds == null &&
            Theme.of(context).platform == TargetPlatform.windows;
        final signature = (
          size,
          devicePixelRatio,
          borderRadius,
          MediaQuery.sizeOf(context),
          MediaQuery.viewInsetsOf(context),
          MediaQuery.paddingOf(context),
          _surfaceBoundsInPhysicalPixels(
            fallbackSize: size,
            devicePixelRatio: devicePixelRatio,
          ),
          widget.blurSigma,
          widget.intensity,
          widget.treatment,
          widget.highContrast,
          effectiveBackdropGroupKey,
          _fragmentProgram,
          widget.lensBounds,
          widget.preparedShader,
          useDesktopLayerHost,
        );
        if (_usesRefraction && signature != _filterConfigSignature) {
          _filterConfigSignature = signature;
          // A new closure/config on every parent rebuild invalidates a stable
          // lens. Keep its identity until optical/layout inputs really change.
          // Position is still resolved at paint time, including ancestor motion.
          _positionAwareFilterConfig = _LiquidGlassImageFilterConfig(
            resolver: (_) => _materialFilter(
              surfaceBoundsPx: _surfaceBoundsInPhysicalPixels(
                fallbackSize: size,
                devicePixelRatio: devicePixelRatio,
              ),
              devicePixelRatio: devicePixelRatio,
              borderRadius: borderRadius,
              groupKey: effectiveBackdropGroupKey,
            ),
          );
          _desktopMaterialResolver = (bounds, bounded) => _materialFilter(
            surfaceBoundsPx: bounds,
            devicePixelRatio: devicePixelRatio,
            borderRadius: borderRadius,
            groupKey: bounded ? null : effectiveBackdropGroupKey,
            boundedBackdrop: bounded,
          );
        }
        if (useDesktopLayerHost) {
          return KeyedSubtree(
            key: LiquidGlassSurface.backdropKey,
            child: _LiquidGlassBackdropLayerHost(
              devicePixelRatio: devicePixelRatio,
              viewportSize: MediaQuery.sizeOf(context),
              blurFilter: _blurFilterForGroup(null),
              backdropGroupKey: effectiveBackdropGroupKey,
              resolveMaterial: _desktopMaterialResolver!,
              materialIsRefractive: _materialIsRefractive,
              child: const SizedBox.expand(),
            ),
          );
        }
        final positionAwareFilter = _usesRefraction
            ? _positionAwareFilterConfig
            : null;
        return BackdropFilter(
          key: LiquidGlassSurface.backdropKey,
          filter: widget.lensBounds != null && !_usesRefraction
              ? _envelopeFailureFilter()
              : positionAwareFilter == null
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

typedef _LiquidGlassMaterialResolver =
    ui.ImageFilter Function(Rect bounds, bool bounded);

/// Unlike choosing two BackdropFilter widgets during layout, this host can
/// switch back to the original single composed filter in the very frame an
/// ancestor starts scaling or rotating. No extra build/layout or timer is
/// needed, and initial layout cannot accidentally select a permanent fallback.
class _LiquidGlassBackdropLayerHost extends SingleChildRenderObjectWidget {
  const _LiquidGlassBackdropLayerHost({
    required this.devicePixelRatio,
    required this.viewportSize,
    required this.blurFilter,
    required this.resolveMaterial,
    this.materialIsRefractive,
    this.backdropGroupKey,
    required super.child,
  });

  final double devicePixelRatio;
  final Size viewportSize;
  final ui.ImageFilter blurFilter;
  final _LiquidGlassMaterialResolver resolveMaterial;
  final bool Function()? materialIsRefractive;
  final BackdropKey? backdropGroupKey;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLiquidGlassBackdrop(
        devicePixelRatio,
        viewportSize,
        blurFilter,
        resolveMaterial,
        backdropGroupKey,
        materialIsRefractive,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderLiquidGlassBackdrop renderObject,
  ) => renderObject.updateConfiguration(
    devicePixelRatio: devicePixelRatio,
    viewportSize: viewportSize,
    blurFilter: blurFilter,
    resolveMaterial: resolveMaterial,
    backdropGroupKey: backdropGroupKey,
    materialIsRefractive: materialIsRefractive,
  );
}

class _RenderLiquidGlassBackdrop extends RenderProxyBox {
  _RenderLiquidGlassBackdrop(
    this._devicePixelRatio,
    this._viewportSize,
    this._blurFilter,
    this._resolveMaterial,
    this._backdropGroupKey,
    this._materialIsRefractive,
  );

  double _devicePixelRatio;
  Size _viewportSize;
  ui.ImageFilter _blurFilter;
  _LiquidGlassMaterialResolver _resolveMaterial;
  BackdropKey? _backdropGroupKey;
  bool Function()? _materialIsRefractive;
  final _composition = LayerHandle<_LiquidGlassCompositionLayer>();
  final _outer = LayerHandle<_LiquidGlassOuterBackdropLayer>();
  final _inner = LayerHandle<_ConditionalLiquidGlassLensLayer>();

  void updateConfiguration({
    required double devicePixelRatio,
    required Size viewportSize,
    required ui.ImageFilter blurFilter,
    required _LiquidGlassMaterialResolver resolveMaterial,
    required BackdropKey? backdropGroupKey,
    required bool Function()? materialIsRefractive,
  }) {
    if (_devicePixelRatio == devicePixelRatio &&
        _viewportSize == viewportSize &&
        _blurFilter == blurFilter &&
        _resolveMaterial == resolveMaterial &&
        _backdropGroupKey == backdropGroupKey &&
        _materialIsRefractive == materialIsRefractive) {
      return;
    }
    _devicePixelRatio = devicePixelRatio;
    _viewportSize = viewportSize;
    _blurFilter = blurFilter;
    _resolveMaterial = resolveMaterial;
    _backdropGroupKey = backdropGroupKey;
    _materialIsRefractive = materialIsRefractive;
    markNeedsPaint();
  }

  Rect _physicalRect(Rect logical) => Rect.fromLTRB(
    logical.left * _devicePixelRatio,
    logical.top * _devicePixelRatio,
    logical.right * _devicePixelRatio,
    logical.bottom * _devicePixelRatio,
  );

  Rect? _boundedLensBounds(Rect surface, Matrix4 transform) {
    if (MatrixUtils.getAsTranslation(transform) == null) return null;
    var capture = surface.intersect(
      Offset.zero & (_viewportSize * _devicePixelRatio),
    );
    RenderObject descendant = this;
    while (descendant.parent != null) {
      final ancestor = descendant.parent!;
      final clip = ancestor.describeApproximatePaintClip(descendant);
      if (clip != null) {
        final clipTransform = ancestor.getTransformTo(null);
        if (MatrixUtils.getAsTranslation(clipTransform) == null) return null;
        capture = capture.intersect(
          _physicalRect(MatrixUtils.transformRect(clipTransform, clip)),
        );
      }
      descendant = ancestor;
    }
    if (!capture.isFinite || capture.isEmpty) return null;
    // Impeller rounds the native blur target out to whole physical pixels.
    // Preserve the full logical lens size, even if the target clips one side.
    return surface.shift(
      -Offset(capture.left.floorToDouble(), capture.top.floorToDouble()),
    );
  }

  bool get _hasPartialOpacityAncestor {
    RenderObject? ancestor = parent;
    while (ancestor != null) {
      final opacity = switch (ancestor) {
        RenderOpacity() => ancestor.opacity,
        RenderAnimatedOpacity() => ancestor.opacity.value,
        RenderSliverOpacity() => ancestor.opacity,
        RenderSliverAnimatedOpacity() => ancestor.opacity.value,
        _ => 1.0,
      };
      if (opacity < 1) return true;
      ancestor = ancestor.parent;
    }
    return false;
  }

  void _resolveComposition() {
    if (!attached || !hasSize || size.isEmpty) return;
    final transform = getTransformTo(null);
    final surface = _physicalRect(
      MatrixUtils.transformRect(transform, Offset.zero & size),
    );
    // Runtime shader snapshots and advanced blends on a partially transparent
    // render target are backend-dependent. Preserve the exact original order
    // during fades: one composed backdrop, then tint/content/optics outside it.
    // The full bounded path resumes at opacity 1 without rebuilding widgets.
    final partialOpacity = _hasPartialOpacityAncestor;
    final bounded = partialOpacity
        ? null
        : _boundedLensBounds(surface, transform);
    final outer = _outer.layer!;
    final inner = _inner.layer!;
    inner.foregroundInside = !partialOpacity;
    if (bounded == null) {
      // Match the half-pixel coordinate rounding of the original material.
      double halfPixel(double value) => (value * 2).roundToDouble() / 2;
      outer
        ..filter = _resolveMaterial(
          Rect.fromLTRB(
            halfPixel(surface.left),
            halfPixel(surface.top),
            halfPixel(surface.right),
            halfPixel(surface.bottom),
          ),
          false,
        )
        ..backdropKey = _backdropGroupKey;
      inner.enabled = false;
    } else {
      final material = _resolveMaterial(bounded, true);
      outer
        ..filter = _blurFilter
        // A grouped capture would skip this surface's already-blurred pixels
        // when the child samples them. Each stage owns its bounded input.
        ..backdropKey = null;
      inner
        ..filter = material
        ..backdropKey = null
        // If shader creation fails, _materialFilter returns a plain blur.
        // Do not run that blur again inside the existing native blur target.
        ..enabled = _materialIsRefractive?.call() ?? true;
    }
    // updateSubtreeNeedsAddToScene ran before this late resolver. A changed
    // inner filter/eligibility must not be hidden inside the outer layer's
    // previously retained native subtree on this same frame.
    outer.invalidateResolvedChild();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    _outer.layer ??= _LiquidGlassOuterBackdropLayer(filter: _blurFilter);
    _inner.layer ??= _ConditionalLiquidGlassLensLayer(filter: _blurFilter);
    _composition.layer ??= _LiquidGlassCompositionLayer(
      resolve: _resolveComposition,
      paintDeferredForeground: (builder) =>
          _inner.layer?.addDeferredForegroundToScene(builder),
    );
    context.pushLayer(_composition.layer!, (outerContext, outerOffset) {
      outerContext.pushLayer(_outer.layer!, (innerContext, innerOffset) {
        innerContext.pushLayer(_inner.layer!, super.paint, innerOffset);
      }, outerOffset);
    }, offset);
  }

  @override
  void dispose() {
    _composition.layer?.resolve = null;
    _composition.layer?.paintDeferredForeground = null;
    _composition.layer = null;
    _outer.layer = null;
    _inner.layer = null;
    super.dispose();
  }
}

/// A transformed ancestor may reuse the entire glass RepaintBoundary without
/// invoking its render object's paint method. Resolve the lens at scene
/// composition time too, so its input origin and eligibility cannot go stale.
/// This does not schedule frames or repaint static controls/shadows.
class _LiquidGlassCompositionLayer extends ContainerLayer {
  _LiquidGlassCompositionLayer({
    required this.resolve,
    required this.paintDeferredForeground,
  });

  VoidCallback? resolve;
  void Function(ui.SceneBuilder builder)? paintDeferredForeground;

  @override
  bool get alwaysNeedsAddToScene => true;

  @override
  void addToScene(ui.SceneBuilder builder) {
    resolve?.call();
    addChildrenToScene(builder);
    paintDeferredForeground?.call(builder);
  }
}

class _LiquidGlassOuterBackdropLayer extends BackdropFilterLayer {
  _LiquidGlassOuterBackdropLayer({required super.filter});

  void invalidateResolvedChild() => markNeedsAddToScene();
}

class _ConditionalLiquidGlassLensLayer extends BackdropFilterLayer {
  _ConditionalLiquidGlassLensLayer({required super.filter})
    : super(blendMode: BlendMode.src);

  bool _enabled = false;
  bool _foregroundInside = true;

  set foregroundInside(bool value) {
    if (_foregroundInside == value) return;
    _foregroundInside = value;
    markNeedsAddToScene();
  }

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    markNeedsAddToScene();
  }

  @override
  void addChildrenToScene(ui.SceneBuilder builder) {
    if (_foregroundInside) super.addChildrenToScene(builder);
  }

  void addDeferredForegroundToScene(ui.SceneBuilder builder) {
    if (!_foregroundInside) super.addChildrenToScene(builder);
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    if (_enabled) {
      super.addToScene(builder);
    } else {
      // A scaled/rotated frame must use exactly one original composed filter,
      // not blur twice or reuse a shader prepared for a local bounded input.
      engineLayer = null;
      addChildrenToScene(builder);
    }
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
      // Integrated chrome shares the color-preserving edge of the floating
      // menu and mini-player. Keep the seam low-energy so it reads as light
      // refracting through the glass instead of a white divider.
      final seamY = math.max(0.0, size.height - 0.5);
      canvas.drawLine(
        Offset(0, math.max(0.0, seamY - 1.1)),
        Offset(size.width, math.max(0.0, seamY - 1.1)),
        Paint()
          ..strokeWidth = highContrast ? 0.9 : 0.55
          ..blendMode = BlendMode.softLight
          ..color = Colors.black.withValues(alpha: alpha(0.06, 0.1))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.1),
      );
      canvas.drawLine(
        Offset(0, seamY),
        Offset(size.width, seamY),
        Paint()
          ..strokeWidth = highContrast ? 0.55 : 0.35
          ..blendMode = BlendMode.softLight
          ..color = Colors.white.withValues(alpha: alpha(0.08, 0.12))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8),
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
