// Regenerate the bundled gallery thumbnails after changing their illustrations:
// flutter test tool/preview_assets/generate_player_style_previews_test.dart
//
// This is an offline asset generator, never imported or run by the application.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/presentation/providers/player_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'player_style_illustration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Roboto-Medium.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Roboto-Black.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('export static player-style thumbnails', (tester) async {
    tester.view.physicalSize = const Size(380, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const boundaryKey = ValueKey('preview-export');
    for (final brightness in Brightness.values) {
      final folder = Directory('assets/player_styles/${brightness.name}');
      await tester.runAsync(() => folder.create(recursive: true));
      // A fixed sample palette illustrates the layout. Gallery labels and the
      // selection border remain native, localized and fully theme-aware.
      final scheme =
          ColorScheme.fromSeed(
            seedColor: AppAccent.green.seedColor,
            brightness: brightness,
          ).copyWith(
            primary: AppAccent.green.seedColor,
            primaryContainer: AppAccent.green.darkColor,
          );
      final theme = ThemeData(
        brightness: brightness,
        colorScheme: scheme,
        platform: TargetPlatform.windows,
        fontFamily: 'Roboto',
        extensions: const [
          AppAccentTheme(accent: AppAccent.green),
          AppSurfaceTheme(backgroundMode: SurfaceBackgroundMode.liquidGlass),
        ],
      );
      for (final style in PlayerStyle.values) {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: Scaffold(
              body: RepaintBoundary(
                key: boundaryKey,
                child: PlayerStyleIllustration(style: style),
              ),
            ),
          ),
        );
        final illustration = tester.element(
          find.byType(PlayerStyleIllustration),
        );
        await tester.runAsync(
          () => precacheImage(
            const ResizeImage(
              AssetImage('assets/icons/4.0x/bstream_icon.png'),
              width: 512,
            ),
            illustration,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '${folder.path}/${style.code}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
    }
  });
}
