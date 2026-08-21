import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} dialogs use the accent-tinted surface', (
      tester,
    ) async {
      const accent = AppAccent.ocean;
      final scheme = ColorScheme.fromSeed(
        seedColor: accent.seedColor,
        brightness: brightness,
      );
      final dialogSurface = AppColors.dialogSurfaceForTheme(accent, scheme);
      final dialogBorder = AppColors.dialogBorderForTheme(accent, scheme);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            colorScheme: scheme,
            dialogTheme: DialogThemeData(
              backgroundColor: dialogSurface,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: dialogBorder),
              ),
            ),
          ),
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(
                  title: Text('Dialog test'),
                  content: Text('Accent surface'),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (widget) => widget is Material && widget.color == dialogSurface,
        ),
        findsOneWidget,
      );
      expect(
        Theme.of(
          tester.element(find.byType(AlertDialog)),
        ).dialogTheme.surfaceTintColor,
        Colors.transparent,
      );
    });
  }
}
