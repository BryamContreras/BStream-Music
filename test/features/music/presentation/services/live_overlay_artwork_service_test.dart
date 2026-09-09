import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/services/live_overlay_artwork_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('center-crops a local cover into a cached PNG data URI', () async {
    final directory = await Directory.systemTemp.createTemp(
      'bstream-live-overlay-artwork-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}cover.png');

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 2, 2),
      Paint()..color = const Color(0xFFFF0000),
    );
    canvas.drawRect(
      const Rect.fromLTWH(2, 0, 2, 2),
      Paint()..color = const Color(0xFF0000FF),
    );
    final source = await recorder.endRecording().toImage(4, 2);
    final png = await source.toByteData(format: ui.ImageByteFormat.png);
    source.dispose();
    await file.writeAsBytes(png!.buffer.asUint8List());

    final service = LiveOverlayArtworkService();
    final dataUri = await service.load(file.path);

    expect(dataUri, startsWith('data:image/png;base64,'));
    final encoded = base64Decode(dataUri!.split(',').last);
    final decoded = image.decodePng(encoded)!;
    expect(decoded.width, liveOverlayArtworkSize);
    expect(decoded.height, liveOverlayArtworkSize);
    expect(decoded.getPixel(10, 48).r.toInt(), 255);
    expect(decoded.getPixel(10, 48).b.toInt(), 0);
    expect(decoded.getPixel(85, 48).r.toInt(), 0);
    expect(decoded.getPixel(85, 48).b.toInt(), 255);
    expect(await service.load(file.path), same(dataUri));
  });
}
