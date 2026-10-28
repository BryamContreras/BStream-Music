import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/providers/lyrics_share_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_share_preview.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_share_photo_cropper.dart';
import 'package:bstream_music/services/sharing/lyrics_image_share_service.dart';
import 'package:bstream_music/services/sharing/lyrics_share_photo_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf')))
        .load();
  });
  testWidgets('five long multilingual lines export completely at 1080px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 680));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _ShareService();
    final lines = [
      '曖昧な言葉なんかじゃ何一つ叶わない いつの日も夢見てた',
      '입술로 전해지는 노래와 마음이 오래도록 우리 곁에 남아',
      'When the night feels long, keep listening to the songs we love',
      'E todas as histórias que guardamos continuam dentro de nós',
      'Si esto no es quererte, entonces dime tú lo que será',
    ];
    await _open(tester, service, lines: lines, textScale: 1.6);
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('lyrics-share-card-lines')))
          .data,
      lines.join('\n'),
    );
    await tester.tap(find.text('Gradiente'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-share-preset-5')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('lyrics-share-preset-5')),
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-share-preset-5')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('lyrics-share-color-1')),
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-share-color-1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('lyrics-share-palette-color-0')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _export(tester, service, save: true);
    expect(service.saved, hasLength(1));
    expect(service.shared, isEmpty);
    expect(find.text('Imagen guardada'), findsOneWidget);
    final png = service.saved.single;
    expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png);
      try {
        final frame = await codec.getNextFrame();
        try {
          expect(frame.image.width, 1080);
          expect(frame.image.height, greaterThan(1080));
          expect(frame.image.height, lessThan(2881));
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      final artifact = Platform.environment['BSTREAM_LYRICS_PREVIEW_ARTIFACT'];
      if (artifact != null) await File(artifact).writeAsBytes(png);
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('shares the rendered image and a valid native sheet anchor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _ShareService();
    await _open(tester, service);
    await _export(tester, service, save: false);
    expect(service.shared, hasLength(1));
    expect(service.title, 'Tú, de qué vas');
    expect(service.origin!.width, greaterThan(0));
    expect(service.origin!.height, greaterThan(0));
    expect(service.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('background options have equal sizes on phones and desktop', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final (size, scale) in [
      (const Size(320, 680), 1.0),
      (const Size(1440, 900), 1.0),
      (const Size(320, 680), 1.6),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await _open(tester, _ShareService(), textScale: scale);
      final buttons = [
        for (final mode in ['gradient', 'artwork', 'blur', 'gallery'])
          find.byKey(ValueKey('lyrics-share-background-$mode')),
      ];
      final expectedSize = tester.getSize(buttons.first);
      for (final button in buttons) {
        expect(tester.getSize(button), expectedSize);
      }
      for (var index = 1; index < buttons.length; index++) {
        final previous = tester.getTopLeft(buttons[index - 1]);
        final current = tester.getTopLeft(buttons[index]);
        expect(
          current.dy > previous.dy ||
              (current.dy == previous.dy && current.dx > previous.dx),
          isTrue,
        );
      }
      final optionsRight = buttons
          .map((button) => tester.getBottomRight(button).dx)
          .reduce((left, right) => left > right ? left : right);
      expect(
        tester
            .getBottomRight(
              find.byKey(const ValueKey('lyrics-share-text-color')),
            )
            .dx,
        closeTo(optionsRight, .1),
      );
      if (size.width == 320 && scale == 1) {
        expect(
          tester.getTopLeft(buttons[0]).dy,
          tester.getTopLeft(buttons[1]).dy,
        );
        expect(
          tester.getTopLeft(buttons[0]).dx,
          tester.getTopLeft(buttons[2]).dx,
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'text button toggles directly and new backgrounds choose contrast',
    (tester) async {
      final service = _ShareService();
      await _open(tester, service);
      Color? foreground() => tester
          .widget<Text>(find.byKey(const ValueKey('lyrics-share-card-lines')))
          .style
          ?.color;
      expect(foreground(), const Color(0xFF12151B));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lyrics-share-text-color')),
          matching: find.text('Oscuro'),
        ),
        findsOneWidget,
      );

      await _toggleTextTone(tester);
      expect(foreground(), Colors.white);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lyrics-share-text-color')),
          matching: find.text('Claro'),
        ),
        findsOneWidget,
      );
      expect(find.byType(PopupMenuItem<dynamic>), findsNothing);
      await _toggleTextTone(tester);
      expect(foreground(), const Color(0xFF12151B));
      await _toggleTextTone(tester);
      await tester.tap(find.text('Gradiente'));
      await tester.pumpAndSettle();
      expect(foreground(), const Color(0xFF12151B));
      await tester.tap(find.byKey(const ValueKey('lyrics-share-preset-5')));
      await tester.pumpAndSettle();
      expect(foreground(), Colors.white);

      await _toggleTextTone(tester);
      expect(foreground(), const Color(0xFF12151B));
      // Re-selecting the same design retains the manual color.
      await tester.tap(find.byKey(const ValueKey('lyrics-share-preset-5')));
      await tester.pumpAndSettle();
      expect(foreground(), const Color(0xFF12151B));
      // Changing the design restores automatic contrast without a menu.
      await tester.tap(find.text('Portada'));
      await tester.pumpAndSettle();
      expect(foreground(), Colors.white);
      await _toggleTextTone(tester);
      await _export(tester, service, save: true);
      expect(service.saved, hasLength(1));
      expect(foreground(), const Color(0xFF12151B));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('gallery photo is cropped before use and exported in the card', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(const Color(0xFFFF2020), BlendMode.src);
    final picture = recorder.endRecording();
    final photo = (await tester.runAsync(() => picture.toImage(640, 320)))!;
    picture.dispose();
    addTearDown(photo.dispose);
    final photoService = _PhotoService(photo);
    final service = _ShareService();
    await _open(tester, service, photoService: photoService);

    await tester.tap(find.text('Galería'));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsSharePhotoCropper), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-share-gallery-photo')),
      findsNothing,
    );
    await tester.drag(
      find.byKey(const ValueKey('lyrics-photo-crop-frame')),
      const Offset(50, 0),
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-photo-crop-confirm')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('lyrics-share-gallery-photo')),
      findsOneWidget,
    );
    expect(find.text('Elegir foto'), findsOneWidget);
    expect(find.text('Ajustar foto'), findsOneWidget);

    // Changing modes retains the approved photo without reopening the picker.
    await tester.tap(find.text('Portada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Galería'));
    await tester.pumpAndSettle();
    expect(photoService.calls, 1);
    await tester.tap(find.text('Ajustar foto'));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsSharePhotoCropper), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('lyrics-share-gallery-photo')),
      findsOneWidget,
    );

    // Cancelling a replacement retains the approved photo, and the outgoing
    // crop route can finish painting before its temporary image is released.
    await tester.tap(find.text('Elegir foto'));
    await tester.pumpAndSettle();
    expect(find.byType(LyricsSharePhotoCropper), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(photoService.calls, 2);
    expect(
      find.byKey(const ValueKey('lyrics-share-gallery-photo')),
      findsOneWidget,
    );

    await _export(tester, service, save: true);
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(service.saved.single);
      final frame = await codec.getNextFrame();
      final bytes = (await frame.image.toByteData())!;
      final x = (frame.image.width * .90).floor();
      final y = (frame.image.height * .82).floor();
      final offset = (y * frame.image.width + x) * 4;
      expect(
        bytes.getUint8(offset),
        greaterThan(bytes.getUint8(offset + 1) * 2),
      );
      expect(
        bytes.getUint8(offset),
        greaterThan(bytes.getUint8(offset + 2) * 2),
      );
      expect(bytes.getUint8(offset), greaterThan(120));
      expect(frame.image.width, 1080);
      frame.image.dispose();
      codec.dispose();
    });
    await _toggleTextTone(tester);
    await _export(tester, service, save: true);
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(service.saved.last);
      final frame = await codec.getNextFrame();
      final bytes = (await frame.image.toByteData())!;
      final offset =
          ((frame.image.height * .82).floor() * frame.image.width +
              (frame.image.width * .90).floor()) *
          4;
      // The lighter white scrim should retain the red photo's saturation.
      expect(bytes.getUint8(offset), greaterThan(240));
      expect(bytes.getUint8(offset + 1), lessThan(170));
      frame.image.dispose();
      codec.dispose();
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelled and failed photo selections retain the current design',
    (tester) async {
      final photoService = _PhotoService(null);
      await _open(tester, _ShareService(), photoService: photoService);
      await tester.tap(find.text('Galería'));
      await tester.pumpAndSettle();
      expect(find.byType(LyricsSharePhotoCropper), findsNothing);
      expect(
        find.byKey(const ValueKey('lyrics-share-gallery-photo')),
        findsNothing,
      );
      expect(_backgroundSelected(tester, 'artwork'), isTrue);
      photoService.error = const FormatException('unsupported image');
      await tester.tap(find.text('Galería'));
      await tester.pumpAndSettle();
      expect(
        find.text(const AppStrings(AppLanguage.spanish).lyricsSharePhotoFailed),
        findsOneWidget,
      );
      expect(_backgroundSelected(tester, 'artwork'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'save cancellation has no success and failure remains retryable',
    (tester) async {
      final service = _ShareService()..saveResult = null;
      await _open(tester, service);
      await _export(tester, service, save: true);
      expect(find.text('Imagen guardada'), findsNothing);
      service.error = StateError('destination unavailable');
      await _export(tester, service, save: true);
      expect(
        find.text(const AppStrings(AppLanguage.spanish).lyricsShareFailed),
        findsOneWidget,
      );
      service.error = null;
      service.saveResult = '/saved/lyrics.png';
      await _export(tester, service, save: true);
      expect(service.saved, hasLength(3));
      expect(find.text('Imagen guardada'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a cancelled chooser dismisses cleanly and Linux offers saving', (
    tester,
  ) async {
    final service = _ShareService(canShare: false);
    await _open(tester, service);
    await tester.tap(find.widgetWithText(FilledButton, 'Compartir letras'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-share-native')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-share-save')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gradiente'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-share-preset-0')), findsOneWidget);
    expect(service.saved, isEmpty);
    expect(service.shared, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

bool _backgroundSelected(WidgetTester tester, String mode) =>
    tester
        .widget<Semantics>(
          find
              .descendant(
                of: find.byKey(ValueKey('lyrics-share-background-$mode')),
                matching: find.byType(Semantics),
              )
              .first,
        )
        .properties
        .selected ==
    true;

Future<void> _toggleTextTone(WidgetTester tester) async {
  final control = find.byKey(const ValueKey('lyrics-share-text-color'));
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

Future<void> _open(
  WidgetTester tester,
  _ShareService service, {
  List<String>? lines,
  double textScale = 1,
  LyricsSharePhotoService? photoService,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appStringsProvider.overrideWithValue(
          const AppStrings(AppLanguage.spanish),
        ),
        lyricsImageShareServiceProvider.overrideWithValue(service),
        if (photoService != null)
          lyricsSharePhotoServiceProvider.overrideWithValue(photoService),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Roboto'),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: LyricsSharePreview(
          data: LyricsShareCardData(
            title: 'Tú, de qué vas',
            artist: 'Franco De Vita',
            lines:
                lines ??
                [
                  'Tú, de qué vas?',
                  'Si esto no es quererte, dime tú lo que será',
                ],
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

class _PhotoService implements LyricsSharePhotoService {
  _PhotoService(this.photo);

  final ui.Image? photo;
  Object? error;
  var calls = 0;

  @override
  Future<ui.Image?> pickPhoto() async {
    calls++;
    if (error case final failure?) throw failure;
    return photo?.clone();
  }
}

Future<void> _export(
  WidgetTester tester,
  _ShareService service, {
  required bool save,
}) async {
  service.completed = Completer<void>();
  await tester.tap(find.widgetWithText(FilledButton, 'Compartir letras'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(ValueKey(save ? 'lyrics-share-save' : 'lyrics-share-native')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  // PNG encoding completes on the raster thread. Alternate real raster work
  // with fake-zone frames so its continuation can reach the injected service.
  for (
    var attempt = 0;
    !service.completed.isCompleted && attempt < 100;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(service.completed.isCompleted, isTrue);
  await tester.pumpAndSettle();
}

class _ShareService implements LyricsImageShareService {
  _ShareService({this.canShare = true});

  @override
  final bool canShare;
  final saved = <Uint8List>[];
  final shared = <Uint8List>[];
  String? title;
  Rect? origin;
  String? saveResult = '/saved/lyrics.png';
  Object? error;
  Completer<void> completed = Completer<void>();

  @override
  Future<String?> saveImage({
    required Uint8List pngBytes,
    required String title,
  }) async {
    saved.add(pngBytes);
    this.title = title;
    completed.complete();
    if (error != null) throw error!;
    return saveResult;
  }

  @override
  Future<void> shareImage({
    required Uint8List pngBytes,
    required String title,
    required Rect sharePositionOrigin,
  }) async {
    shared.add(pngBytes);
    this.title = title;
    origin = sharePositionOrigin;
    completed.complete();
    if (error != null) throw error!;
  }
}
