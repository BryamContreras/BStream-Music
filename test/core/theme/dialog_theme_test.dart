import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_dialog.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const accent = AppAccent.ocean;

  for (final brightness in Brightness.values) {
    for (final backgroundMode in SurfaceBackgroundMode.values) {
      testWidgets(
        '${brightness.name} ${backgroundMode.name} dialogs use the themed '
        'surface, border, and barrier',
        (tester) async {
          final scheme = ColorScheme.fromSeed(
            seedColor: accent.seedColor,
            brightness: brightness,
          );
          final dialogSurface = AppColors.dialogSurfaceForTheme(
            accent,
            scheme,
            backgroundMode: backgroundMode,
          );
          final dialogBorder = AppColors.dialogBorderForTheme(
            accent,
            scheme,
            backgroundMode: backgroundMode,
          );
          final dialogBarrier = AppColors.dialogBarrierForTheme(
            scheme,
            backgroundMode: backgroundMode,
          );

          expect(
            dialogSurface,
            _expectedDialogSurface(accent, scheme, backgroundMode),
          );
          expect(
            dialogBorder,
            _expectedDialogBorder(accent, scheme, backgroundMode),
          );
          expect(dialogBarrier, _expectedDialogBarrier(scheme, backgroundMode));

          final accentSurface = AppColors.dialogSurfaceForTheme(
            accent,
            scheme,
            backgroundMode: SurfaceBackgroundMode.accent,
          );
          final accentBorder = AppColors.dialogBorderForTheme(
            accent,
            scheme,
            backgroundMode: SurfaceBackgroundMode.accent,
          );
          if (backgroundMode.usesBackdrop) {
            expect(dialogSurface.a, lessThan(accentSurface.a));
            expect(dialogBorder.a, lessThan(accentBorder.a));
            expect(dialogBarrier.a, lessThan(Colors.black54.a));
          } else {
            expect(dialogSurface, accentSurface);
            expect(dialogBorder, accentBorder);
            expect(dialogBarrier, Colors.black54);
          }

          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                useMaterial3: true,
                brightness: brightness,
                colorScheme: scheme,
                extensions: [
                  const AppAccentTheme(accent: accent),
                  AppSurfaceTheme(backgroundMode: backgroundMode),
                ],
                dialogTheme: DialogThemeData(
                  backgroundColor: dialogSurface,
                  surfaceTintColor: Colors.transparent,
                  barrierColor: dialogBarrier,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: dialogBorder),
                  ),
                ),
              ),
              home: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showAppDialog<void>(
                    context: context,
                    builder: (_) => AlertDialog(
                      key: ValueKey(
                        'dialog-${brightness.name}-${backgroundMode.name}',
                      ),
                      title: const Text('Dialog test'),
                      content: Text(backgroundMode.name),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          );

          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();

          final alertDialog = find.byKey(
            ValueKey('dialog-${brightness.name}-${backgroundMode.name}'),
          );
          final dialogMaterial = tester
              .widgetList<Material>(
                find.descendant(
                  of: alertDialog,
                  matching: find.byType(Material),
                ),
              )
              .firstWhere((material) => material.type == MaterialType.card);
          final materialShape = dialogMaterial.shape! as RoundedRectangleBorder;
          final modalBarrier = tester.widget<ModalBarrier>(
            find.byType(ModalBarrier).last,
          );

          expect(dialogMaterial.color, dialogSurface);
          expect(dialogMaterial.surfaceTintColor, Colors.transparent);
          expect(materialShape.side.color, dialogBorder);
          expect(modalBarrier.color, dialogBarrier);
          expect(
            Theme.of(tester.element(alertDialog)).dialogTheme.backgroundColor,
            dialogSurface,
          );
          expect(
            Theme.of(tester.element(alertDialog)).dialogTheme.barrierColor,
            dialogBarrier,
          );
          expect(find.byType(BackdropFilter), switch (backgroundMode) {
            SurfaceBackgroundMode.accent => findsNothing,
            SurfaceBackgroundMode.transparent => findsOneWidget,
            // LiquidGlassSurface composes refraction and blur into one capture.
            SurfaceBackgroundMode.liquidGlass => findsOneWidget,
          });
          if (backgroundMode == SurfaceBackgroundMode.transparent) {
            expect(
              find.descendant(
                of: alertDialog,
                matching: find.byKey(
                  const ValueKey('app-dialog-local-backdrop-filter'),
                ),
              ),
              findsOneWidget,
            );
            expect(
              find.ancestor(
                of: find.byType(ModalBarrier).last,
                matching: find.byType(BackdropFilter),
              ),
              findsNothing,
            );
            expect(
              find.descendant(
                of: find.byKey(
                  const ValueKey('app-dialog-local-backdrop-filter'),
                ),
                matching: find.text('Dialog test'),
              ),
              findsNothing,
            );

            final filterRect = tester.getRect(
              find.byKey(const ValueKey('app-dialog-local-backdrop-filter')),
            );
            final materialRect = tester.getRect(
              find.descendant(
                of: alertDialog,
                matching: find.byWidget(dialogMaterial),
              ),
            );
            final barrierRect = tester.getRect(find.byType(ModalBarrier).last);
            expect(filterRect, materialRect);
            expect(filterRect.width, lessThan(barrierRect.width));
            expect(filterRect.height, lessThan(barrierRect.height));

            final glassDecoration = tester.widget<DecoratedBox>(
              find.byKey(const ValueKey('app-dialog-glass-gradient')),
            );
            final gradient =
                (glassDecoration.decoration as BoxDecoration).gradient!
                    as LinearGradient;
            expect(gradient.colors, hasLength(3));
            expect(gradient.colors.every((color) => color.a > 0), isTrue);
          } else if (backgroundMode == SurfaceBackgroundMode.liquidGlass) {
            final liquidGlass = find.byKey(
              const ValueKey('app-dialog-liquid-glass'),
            );
            final material = tester.widget<LiquidGlassSurface>(liquidGlass);

            expect(liquidGlass, findsOneWidget);
            expect(material.blurSigma, appDialogBlurSigma);
            expect(material.borderRadius, BorderRadius.circular(12));
            expect(
              find.descendant(
                of: liquidGlass,
                matching: find.byKey(LiquidGlassSurface.backdropKey),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: liquidGlass,
                matching: find.byKey(LiquidGlassSurface.opticsKey),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: liquidGlass,
                matching: find.byKey(LiquidGlassSurface.adaptiveEdgeKey),
              ),
              // Refraction is composed into the single backdrop capture.
              findsNothing,
            );
            expect(
              find.descendant(
                of: liquidGlass,
                matching: find.byKey(LiquidGlassSurface.shadowKey),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: liquidGlass,
                matching: find.byType(LiquidGlassHoverTarget),
              ),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('app-dialog-local-backdrop-filter')),
              findsNothing,
            );
          }

          final route = ModalRoute.of(tester.element(alertDialog));
          expect(route, isA<DialogRoute<void>>());
          expect(route?.transitionDuration, const Duration(milliseconds: 150));
          expect(
            route?.traversalEdgeBehavior,
            TraversalEdgeBehavior.closedLoop,
          );
        },
      );
    }
  }

  testWidgets(
    'showAppDialog preserves non-dismissible barriers and pop results',
    (tester) async {
      bool? result;
      final scheme = ColorScheme.fromSeed(
        seedColor: accent.seedColor,
        brightness: Brightness.dark,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: scheme,
            extensions: const [
              AppAccentTheme(accent: accent),
              AppSurfaceTheme(
                backgroundMode: SurfaceBackgroundMode.transparent,
              ),
            ],
          ),
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showAppDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Locked dialog'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: const Text('Confirm'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Open locked'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open locked'));
      await tester.pumpAndSettle();

      final dialog = find.text('Locked dialog');
      expect(dialog, findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
      final route = ModalRoute.of(tester.element(dialog));
      expect(route?.barrierDismissible, isFalse);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      expect(result, isNull);

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(result, isTrue);
    },
  );

  testWidgets(
    'direct AlertDialog adaptation preserves scrolling, insets, actions, and focus',
    (tester) async {
      String? result;
      final scheme = ColorScheme.fromSeed(
        seedColor: accent.seedColor,
        brightness: Brightness.light,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: scheme,
            extensions: const [
              AppAccentTheme(accent: accent),
              AppSurfaceTheme(
                backgroundMode: SurfaceBackgroundMode.transparent,
              ),
            ],
          ),
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showAppDialog<String>(
                  context: context,
                  barrierDismissible: false,
                  builder: (dialogContext) => AlertDialog(
                    key: const ValueKey('adapted-alert-dialog'),
                    scrollable: true,
                    insetPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 32,
                    ),
                    title: const Text('Preserved layout'),
                    content: const TextField(
                      key: ValueKey('focused-dialog-field'),
                      autofocus: true,
                    ),
                    actionsAlignment: MainAxisAlignment.spaceBetween,
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () =>
                            Navigator.of(dialogContext).pop('saved'),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Open adapted'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open adapted'));
      await tester.pumpAndSettle();

      final adapted = tester.widget<AppAlertDialog>(
        find.byKey(const ValueKey('adapted-alert-dialog')),
      );
      expect(adapted.scrollable, isTrue);
      expect(
        adapted.insetPadding,
        const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      );
      expect(adapted.actionsAlignment, MainAxisAlignment.spaceBetween);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('adapted-alert-dialog')),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('focused-dialog-field')),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.focusNode.hasFocus, isTrue);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(ModalBarrier).last,
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, 'saved');
    },
  );
}

Color _expectedDialogSurface(
  AppAccent accent,
  ColorScheme colors,
  SurfaceBackgroundMode backgroundMode,
) {
  final isDark = colors.brightness == Brightness.dark;
  if (backgroundMode.isLiquidGlass) {
    return (isDark ? Colors.black : Colors.white).withValues(
      alpha: isDark ? 0.2 : 0.26,
    );
  }
  final tint = isDark ? accent.seedColor : accent.darkColor;
  final surfaceAlpha = switch (backgroundMode) {
    SurfaceBackgroundMode.accent => 0.97,
    SurfaceBackgroundMode.transparent => isDark ? 0.7 : 0.78,
    SurfaceBackgroundMode.liquidGlass => 0.0,
  };
  final tintStrength = switch (backgroundMode) {
    SurfaceBackgroundMode.accent => isDark ? 0.08 : 0.06,
    SurfaceBackgroundMode.transparent => isDark ? 0.09 : 0.07,
    SurfaceBackgroundMode.liquidGlass => 0.0,
  };
  return Color.alphaBlend(
    tint.withValues(alpha: tintStrength),
    colors.surface.withValues(alpha: surfaceAlpha),
  );
}

Color _expectedDialogBorder(
  AppAccent accent,
  ColorScheme colors,
  SurfaceBackgroundMode backgroundMode,
) {
  final isDark = colors.brightness == Brightness.dark;
  if (backgroundMode.isLiquidGlass) {
    return (isDark ? Colors.white : Colors.black).withValues(
      alpha: isDark ? 0.24 : 0.14,
    );
  }
  final tintStrength = switch (backgroundMode) {
    SurfaceBackgroundMode.accent => isDark ? 0.24 : 0.18,
    SurfaceBackgroundMode.transparent => isDark ? 0.32 : 0.24,
    SurfaceBackgroundMode.liquidGlass => isDark ? 0.4 : 0.3,
  };
  final tint = colors.brightness == Brightness.dark
      ? accent.seedColor
      : accent.darkColor;
  return Color.alphaBlend(
    tint.withValues(alpha: tintStrength),
    colors.outlineVariant,
  ).withValues(alpha: backgroundMode.usesBackdrop ? 0.74 : 0.9);
}

Color _expectedDialogBarrier(
  ColorScheme colors,
  SurfaceBackgroundMode backgroundMode,
) {
  final isDark = colors.brightness == Brightness.dark;
  return switch (backgroundMode) {
    SurfaceBackgroundMode.accent => Colors.black54,
    SurfaceBackgroundMode.transparent => Colors.black.withValues(
      alpha: isDark ? 0.32 : 0.22,
    ),
    SurfaceBackgroundMode.liquidGlass => Colors.black.withValues(
      alpha: isDark ? 0.26 : 0.18,
    ),
  };
}
