import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:bstream_music/features/music/presentation/providers/live_widget_style.dart';
import 'package:bstream_music/features/music/presentation/widgets/live_widget_style_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Ahem's square test glyphs conceal the overflow produced by Roboto's
    // actual ascent/descent in the fixed-height browser-source preview.
    final font = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold', 'Black']) {
      font.addFont(rootBundle.load('assets/fonts/Roboto-$weight.ttf'));
    }
    await font.load();
  });

  for (final style in LiveWidgetStyle.values) {
    for (final scale in [1.0, 1.5, 2.5]) {
      for (final language in AppLanguage.values) {
        testWidgets(
          '${style.code} preview fits with real fonts, $language, scale $scale',
          (tester) async {
            tester.view
              ..devicePixelRatio = 1
              ..physicalSize = const Size(1280, 900);
            addTearDown(() {
              tester.view
                ..resetPhysicalSize()
                ..resetDevicePixelRatio();
            });

            for (final width in [320.0, 760.0, 1192.0]) {
              await tester.pumpWidget(
                MaterialApp(
                  theme: ThemeData(platform: TargetPlatform.windows),
                  home: Scaffold(
                    body: MediaQuery(
                      data: MediaQueryData(
                        textScaler: TextScaler.linear(scale),
                      ),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: width,
                          child: LiveWidgetPreview(
                            style: style,
                            accent: AppAccent.blue,
                            strings: AppStrings(language),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: 'Width $width');

              final bounds = tester.getRect(find.byType(LiveWidgetPreview));
              expect(bounds.width, width);
              for (final text in find.byType(Text).evaluate()) {
                final rect = tester.getRect(find.byWidget(text.widget));
                expect(rect.top, greaterThanOrEqualTo(bounds.top));
                expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
                expect(rect.left, greaterThanOrEqualTo(bounds.left));
                expect(rect.right, lessThanOrEqualTo(bounds.right));
              }
            }
          },
        );
      }
    }
  }
}
