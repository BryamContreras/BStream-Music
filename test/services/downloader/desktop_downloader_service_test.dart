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

  test('uses configured yt-dlp and bundled FFmpeg tools', () async {
    final temp = await Directory.systemTemp.createTemp(
      'bstream_desktop_tools_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final configuredDirectory = Directory(p.join(temp.path, 'configured'));
    final bundledDirectory = Directory(p.join(temp.path, 'tools'));
    await configuredDirectory.create(recursive: true);
    await bundledDirectory.create(recursive: true);
    final ytDlp = File(p.join(configuredDirectory.path, 'yt-dlp.exe'));
    final ffmpeg = File(p.join(bundledDirectory.path, 'ffmpeg.exe'));
    await ytDlp.writeAsString('');
    await ffmpeg.writeAsString('');

    final service = DesktopDownloaderService(
      toolDirectories: [bundledDirectory],
    );
    addTearDown(service.dispose);

    await service.setYtDlpPath(configuredDirectory.path);

    expect(await service.getYtDlpPath(), ytDlp.path);
    expect(await service.getFfmpegPath(), ffmpeg.path);
  });

  test('does not fall back to a system FFmpeg executable', () async {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    expect(await service.getFfmpegPath(), isNull);
    expect(await service.hasFfmpeg(), isFalse);
  });
}
