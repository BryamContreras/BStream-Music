import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/services/downloader/desktop_downloader_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('detects bundled yt-dlp on Windows tools folder', () async {
    final toolsDirectory = Directory(
      p.join(Directory.current.path, 'windows', 'tools'),
    );
    final ytDlp = File(p.join(toolsDirectory.path, 'yt-dlp.exe'));

    if (!ytDlp.existsSync()) {
      markTestSkipped(
        'Bundled Windows yt-dlp is not available on this machine.',
      );
      return;
    }

    final service = DesktopDownloaderService();

    expect(await service.getYtDlpPath(), ytDlp.path);
    expect(await service.hasYtDlp(), isTrue);

    await service.dispose();
  });

  test('uses configured yt-dlp', () async {
    final temp = await Directory.systemTemp.createTemp(
      'bstream_desktop_tools_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final configuredDirectory = Directory(p.join(temp.path, 'configured'));
    await configuredDirectory.create(recursive: true);
    final ytDlp = File(p.join(configuredDirectory.path, 'yt-dlp.exe'));
    await ytDlp.writeAsString('');

    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    await service.setYtDlpPath(configuredDirectory.path);

    expect(await service.getYtDlpPath(), ytDlp.path);
  });

  test('prefers bundled yt-dlp over a persisted bare command', () async {
    final temp = await Directory.systemTemp.createTemp(
      'bstream_bundled_ytdlp_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final executableName = Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
    final bundledYtDlp = File(p.join(temp.path, executableName));
    await bundledYtDlp.writeAsString('');

    final service = DesktopDownloaderService(toolDirectories: [temp]);
    addTearDown(service.dispose);

    await service.setYtDlpPath('yt-dlp');

    expect(await service.getYtDlpPath(), bundledYtDlp.path);
  });

  test('enables bundled Deno explicitly and keeps Node as fallback', () async {
    final temp = await Directory.systemTemp.createTemp(
      'bstream_desktop_javascript_runtime_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final ytDlpName = Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
    final denoName = Platform.isWindows ? 'deno.exe' : 'deno';
    final ytDlp = File(p.join(temp.path, ytDlpName));
    final deno = File(p.join(temp.path, denoName));
    await Future.wait([ytDlp.writeAsString(''), deno.writeAsString('')]);

    final service = DesktopDownloaderService(toolDirectories: [temp]);
    addTearDown(service.dispose);

    final arguments = service.buildYtDlpProcessArguments(ytDlp.path, const [
      '--dump-single-json',
      'https://www.youtube.com/watch?v=abcdefghijk',
    ]);

    expect(arguments.first, '--ignore-config');
    expect(
      arguments,
      containsAllInOrder([
        '--js-runtimes',
        'deno:${p.absolute(deno.path)}',
        '--js-runtimes',
        'node',
        '--dump-single-json',
      ]),
    );
    expect(arguments.where((value) => value == '--js-runtimes'), hasLength(2));
  });

  test('enables Node fallback when bundled Deno is unavailable', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    final arguments = service.buildYtDlpProcessArguments('yt-dlp', const [
      '--ignore-config',
      '--version',
    ]);

    expect(arguments.first, '--ignore-config');
    expect(
      arguments,
      containsAllInOrder(const ['--js-runtimes', 'node', '--version']),
    );
    expect(arguments.where((value) => value.startsWith('deno:')), isEmpty);
  });

  test('does not duplicate JavaScript runtimes already configured', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    final arguments = service.buildYtDlpProcessArguments('yt-dlp', const [
      '--js-runtimes',
      'deno:C:/tools/deno.exe',
      '--js-runtimes=node',
      '--version',
    ]);

    expect(arguments.where((value) => value == '--js-runtimes'), hasLength(1));
    expect(
      arguments.where((value) => value == '--js-runtimes=node'),
      hasLength(1),
    );
  });

  test('requests 15 search results from desktop yt-dlp', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    expect(
      service.buildSearchArguments('Artist - Song'),
      contains('ytsearch15:Artist - Song'),
    );
  });

  test('builds native audio arguments without FFmpeg post-processing', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    const url = 'https://www.youtube.com/watch?v=abcdefghijk';
    final outputDirectory = p.join('downloads', 'audio');
    final options = DownloadOptions(
      outputDirectory: outputDirectory,
      fileName: 'Artist - Title',
    );

    final arguments = service.buildAudioDownloadArguments(url, options);

    expect(arguments.first, '--ignore-config');
    expect(
      arguments,
      containsAllInOrder(['--fixup', 'never', '--downloader', 'native']),
    );
    expect(
      arguments,
      containsAllInOrder([
        '--progress',
        '--progress-template',
        'download:BSTREAM_PROGRESS|%(progress._percent_str)s|'
            '%(progress.eta)s',
        '--progress-delta',
        '0.2',
        '--print',
        'after_move:filepath',
      ]),
    );
    expect(
      arguments,
      containsAllInOrder([
        '-f',
        'bestaudio[ext=m4a]/bestaudio[ext=aac]/'
            'bestaudio[acodec^=mp4a]/bestaudio[acodec^=aac]/bestaudio',
        '--restrict-filenames',
        '-o',
        p.join(outputDirectory, 'Artist - Title.%(ext)s'),
        url,
      ]),
    );
    expect(arguments, isNot(contains('-x')));
    expect(arguments, isNot(contains('--audio-format')));
    expect(arguments, isNot(contains('--audio-quality')));
    expect(arguments, isNot(contains('--embed-metadata')));
    expect(arguments, isNot(contains('--embed-thumbnail')));
    expect(arguments, isNot(contains('--ffmpeg-location')));
  });

  test('parses structured yt-dlp progress with numeric ETA', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    final sample = service.parseAudioDownloadProgressLine(
      'BSTREAM_PROGRESS| 37.4%|9',
    );

    expect(sample, isNotNull);
    expect(sample!.progress, closeTo(0.374, 0.0001));
    expect(sample.eta, const Duration(seconds: 9));
  });

  test('parses standard progress when ETA is unavailable', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    final sample = service.parseAudioDownloadProgressLine(
      '[download]   0.5% of 3.00MiB at 1.00MiB/s ETA Unknown',
    );

    expect(sample, isNotNull);
    expect(sample!.progress, closeTo(0.005, 0.0001));
    expect(sample.eta, isNull);
  });

  test('parses standard progress and clock ETA', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    final sample = service.parseAudioDownloadProgressLine(
      '[download]  42.7% of 3.00MiB at 1.00MiB/s ETA 00:02',
    );

    expect(sample, isNotNull);
    expect(sample!.progress, closeTo(0.427, 0.0001));
    expect(sample.eta, const Duration(seconds: 2));
    expect(service.parseAudioDownloadProgressLine('WARNING: retrying'), isNull);
  });

  test('recognizes native audio containers returned by yt-dlp', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    for (final extension in const [
      'm4a',
      'm4b',
      'aac',
      'mp4',
      'webm',
      'ogg',
      'opus',
      'mp3',
      'flac',
      'wav',
      'mka',
    ]) {
      expect(
        service.isSupportedAudioFilePath('track.$extension'),
        isTrue,
        reason: '.$extension should be recognized as audio',
      );
    }
    expect(service.isSupportedAudioFilePath('track.part'), isFalse);
    expect(service.isSupportedAudioFilePath('cover.jpg'), isFalse);
  });
}
