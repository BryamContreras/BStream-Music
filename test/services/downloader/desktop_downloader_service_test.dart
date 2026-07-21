import 'dart:io';

import 'package:bstream_music/services/downloader/desktop_downloader_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('detects bundled yt-dlp and FFmpeg on Windows tools folder', () async {
    final toolsDirectory = Directory(
      p.join(Directory.current.path, 'windows', 'tools'),
    );
    final ytDlp = File(p.join(toolsDirectory.path, 'yt-dlp.exe'));
    final ffmpeg = File(p.join(toolsDirectory.path, 'ffmpeg.exe'));

    if (!ytDlp.existsSync() || !ffmpeg.existsSync()) {
      markTestSkipped(
        'Bundled Windows tools are not available on this machine.',
      );
      return;
    }

    final service = DesktopDownloaderService();

    expect(await service.getYtDlpPath(), ytDlp.path);
    expect(await service.getFfmpegPath(), ffmpeg.path);
    expect(await service.hasYtDlp(), isTrue);
    expect(await service.hasFfmpeg(), isTrue);

    await service.dispose();
  });

  test('resolves configured tool directories without executing them', () async {
    final temp = await Directory.systemTemp.createTemp(
      'bstream_desktop_tools_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final ytDlp = File(p.join(temp.path, 'yt-dlp.exe'));
    final ffmpeg = File(p.join(temp.path, 'ffmpeg.exe'));
    await ytDlp.writeAsString('');
    await ffmpeg.writeAsString('');

    final service = DesktopDownloaderService();
    addTearDown(service.dispose);

    await service.setYtDlpPath(temp.path);
    await service.setFfmpegPath(temp.path);

    expect(await service.getYtDlpPath(), ytDlp.path);
    expect(await service.getFfmpegPath(), ffmpeg.path);
  });
}
