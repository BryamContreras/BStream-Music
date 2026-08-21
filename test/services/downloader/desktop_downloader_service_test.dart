import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/core/errors/app_exception.dart';
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
    expect(arguments, containsAllInOrder(const ['--socket-timeout', '20']));
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

  test('does not replace an explicitly configured socket timeout', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    final arguments = service.buildYtDlpProcessArguments('yt-dlp', const [
      '--socket-timeout=37',
      '--version',
    ]);

    expect(arguments.where((value) => value.startsWith('--socket-timeout')), [
      '--socket-timeout=37',
    ]);
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

  test('requests 20 search results from desktop yt-dlp', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    expect(
      service.buildSearchArguments('Artist - Song'),
      contains('ytsearch20:Artist - Song'),
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
        '--extractor-args',
        'youtube:player_client=web_embedded',
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

  test('builds chunked managed-playback arguments with format fallback', () {
    final service = DesktopDownloaderService(toolDirectories: const []);
    addTearDown(service.dispose);

    const url = 'https://www.youtube.com/watch?v=abcdefghijk';
    final outputDirectory = p.join('cache', 'managed');
    final arguments = service.buildManagedPlaybackArguments(
      url,
      outputDirectory,
      playerClient: 'web_embedded',
    );

    expect(
      arguments,
      containsAllInOrder([
        '--newline',
        '--progress',
        '--progress-template',
        'download:BSTREAM_PROGRESS|%(progress._percent_str)s|'
            '%(progress.eta)s',
        '--progress-delta',
        '1',
        '--downloader',
        'native',
        '--http-chunk-size',
        '1M',
        '--max-filesize',
        service.managedPlaybackMaximumEntryBytesForTesting.toString(),
        '--print',
        'after_move:filepath',
      ]),
    );
    expect(arguments, isNot(contains('--no-progress')));
    expect(
      arguments,
      containsAllInOrder([
        '-f',
        'bestaudio[ext=m4a]/bestaudio[ext=aac]/'
            'bestaudio[acodec^=mp4a]/bestaudio[acodec^=aac]/bestaudio',
        '--extractor-args',
        'youtube:player_client=web_embedded',
        '-o',
        p.join(outputDirectory, '%(id)s.%(format_id)s.%(ext)s'),
        url,
      ]),
    );
    expect(arguments, isNot(contains('-x')));
    expect(arguments, isNot(contains('--audio-format')));
  });

  test(
    'managed playback pruning bounds bytes and preserves active file',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'bstream_managed_playback_bounds_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final service = DesktopDownloaderService(
        toolDirectories: const [],
        managedPlaybackMaximumFiles: 4,
        managedPlaybackMaximumBytes: 10,
        managedPlaybackMaximumEntryBytes: 8,
      );
      addTearDown(service.dispose);
      final old = File(p.join(temp.path, 'old.140.m4a'));
      final active = File(p.join(temp.path, 'active.140.m4a'));
      await old.writeAsBytes(List<int>.filled(6, 1));
      await active.writeAsBytes(List<int>.filled(6, 2));
      final now = DateTime.now();
      await old.setLastModified(now.subtract(const Duration(minutes: 2)));
      await active.setLastModified(now.subtract(const Duration(minutes: 1)));

      await service.trimManagedPlaybackCacheForTesting(
        temp,
        protectedPath: active.path,
      );

      expect(await active.exists(), isTrue);
      expect(await old.exists(), isFalse);
    },
  );

  test(
    'preparing a replacement does not prune the previously active file',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'bstream_managed_playback_handoff_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final managedDirectory = Directory(p.join(temp.path, 'managed'));
      await managedDirectory.create(recursive: true);
      final executable = File(
        p.join(temp.path, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'),
      );
      await executable.writeAsString('test executable');

      var starts = 0;
      final service = DesktopDownloaderService(
        toolDirectories: const [],
        managedPlaybackDirectory: () async => managedDirectory,
        managedPlaybackMaximumFiles: 2,
        managedPlaybackMaximumBytes: 10,
        managedPlaybackMaximumEntryBytes: 8,
        processStarter: (_, _) async {
          starts++;
          final name = starts == 1 ? 'active' : 'replacement';
          final output = File(p.join(managedDirectory.path, '$name.140.m4a'));
          await output.writeAsBytes(List<int>.filled(6, starts));
          final process = _ControllableProcess(90500 + starts);
          process.completeSuccessfully('${output.path}\n');
          return process;
        },
        processTerminator: (process) => process.kill(),
      );
      addTearDown(service.dispose);
      await service.setYtDlpPath(executable.path);

      final active = await service.prepareManagedPlayback(
        'https://www.youtube.com/watch?v=active',
      );
      final stale = File(p.join(managedDirectory.path, 'stale.140.m4a'));
      await stale.writeAsBytes(const [9, 9]);

      final replacement = await service.prepareManagedPlayback(
        'https://www.youtube.com/watch?v=replacement',
      );

      expect(starts, 2);
      expect(await File(active.filePath).exists(), isTrue);
      expect(await File(replacement.filePath).exists(), isTrue);
      expect(await stale.exists(), isFalse);
    },
  );

  test(
    'managed playback cancels active work and skips superseded requests',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'bstream_managed_playback_latest_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final managedDirectory = Directory(p.join(temp.path, 'managed'));
      await managedDirectory.create(recursive: true);
      final executable = File(
        p.join(temp.path, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'),
      );
      await executable.writeAsString('test executable');

      final firstStarted = Completer<void>();
      final startedUrls = <String>[];
      late _ControllableProcess firstProcess;
      var starts = 0;
      final service = DesktopDownloaderService(
        toolDirectories: const [],
        managedPlaybackDirectory: () async => managedDirectory,
        processStarter: (executable, arguments) async {
          starts++;
          startedUrls.add(arguments.last);
          final process = _ControllableProcess(91000 + starts);
          if (starts == 1) {
            firstProcess = process;
            firstStarted.complete();
          } else {
            final output = File(
              p.join(managedDirectory.path, 'latest.140.m4a'),
            );
            await output.writeAsBytes(const [1, 2, 3, 4]);
            process.completeSuccessfully('${output.path}\n');
          }
          return process;
        },
        processTerminator: (process) => process.kill(),
      );
      addTearDown(service.dispose);
      await service.setYtDlpPath(executable.path);

      final first = service.prepareManagedPlayback(
        'https://www.youtube.com/watch?v=first',
      );
      final firstFailure = expectLater(
        first,
        throwsA(
          isA<DownloaderException>().having(
            (error) => error.code,
            'code',
            'yt_dlp_managed_playback_superseded',
          ),
        ),
      );
      await firstStarted.future;

      final pending = service.prepareManagedPlayback(
        'https://www.youtube.com/watch?v=pending',
      );
      final pendingFailure = expectLater(
        pending,
        throwsA(
          isA<DownloaderException>().having(
            (error) => error.code,
            'code',
            'yt_dlp_managed_playback_superseded',
          ),
        ),
      );
      final latest = service.prepareManagedPlayback(
        'https://www.youtube.com/watch?v=latest',
      );

      final resource = await latest;
      await Future.wait([firstFailure, pendingFailure]);

      expect(firstProcess.killCalls, greaterThanOrEqualTo(1));
      expect(starts, 2);
      expect(startedUrls, [
        'https://www.youtube.com/watch?v=first',
        'https://www.youtube.com/watch?v=latest',
      ]);
      expect(
        resource.filePath,
        p.join(managedDirectory.path, 'latest.140.m4a'),
      );
    },
  );

  test('kills metadata extraction after its resolution deadline', () async {
    final temp = await Directory.systemTemp.createTemp(
      'bstream_ytdlp_resolution_watchdog_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final executable = File(
      p.join(temp.path, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'),
    );
    await executable.writeAsString('test executable');
    final process = _ControllableProcess(92001);
    final service = DesktopDownloaderService(
      toolDirectories: const [],
      processResolutionTimeout: const Duration(milliseconds: 20),
      processIdleTimeout: const Duration(seconds: 1),
      processDownloadTotalTimeout: const Duration(seconds: 1),
      processStarter: (_, _) async => process,
      processTerminator: (active) => active.kill(),
    );
    addTearDown(service.dispose);
    await service.setYtDlpPath(executable.path);

    await expectLater(
      service.getInfo('https://www.youtube.com/watch?v=abcdefghijk'),
      throwsA(
        isA<DownloaderException>().having(
          (error) => error.code,
          'code',
          'yt_dlp_process_resolution_timeout',
        ),
      ),
    );

    expect(process.killCalls, 1);
  });

  test('kills a download that stops reporting activity', () async {
    final temp = await Directory.systemTemp.createTemp(
      'bstream_ytdlp_idle_watchdog_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final executable = File(
      p.join(temp.path, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'),
    );
    await executable.writeAsString('test executable');
    final process = _ControllableProcess(92002);
    final service = DesktopDownloaderService(
      toolDirectories: const [],
      processResolutionTimeout: const Duration(seconds: 1),
      processIdleTimeout: const Duration(milliseconds: 20),
      processDownloadTotalTimeout: const Duration(seconds: 1),
      processStarter: (_, _) async => process,
      processTerminator: (active) => active.kill(),
    );
    addTearDown(service.dispose);
    await service.setYtDlpPath(executable.path);

    await expectLater(
      service.downloadAudio(
        'https://www.youtube.com/watch?v=abcdefghijk',
        DownloadOptions(outputDirectory: p.join(temp.path, 'audio')),
      ),
      throwsA(
        isA<DownloaderException>().having(
          (error) => error.code,
          'code',
          'yt_dlp_process_idle_timeout',
        ),
      ),
    );

    expect(process.killCalls, 1);
  });

  test('stdout progress renews the idle watchdog for long downloads', () async {
    final temp = await Directory.systemTemp.createTemp(
      'bstream_ytdlp_renewed_watchdog_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final executable = File(
      p.join(temp.path, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'),
    );
    await executable.writeAsString('test executable');
    final outputDirectory = Directory(p.join(temp.path, 'audio'));
    final output = File(p.join(outputDirectory.path, 'completed.m4a'));
    final process = _ControllableProcess(92003);
    Timer? progressTimer;
    var samples = 0;
    final service = DesktopDownloaderService(
      toolDirectories: const [],
      processResolutionTimeout: const Duration(seconds: 1),
      // Keep a generous scheduler margin: this test validates that activity
      // renews the watchdog, not that Windows can deliver 15 ms timers while
      // the full Flutter suite is loading other isolates.
      processIdleTimeout: const Duration(milliseconds: 150),
      processDownloadTotalTimeout: const Duration(seconds: 1),
      processStarter: (_, _) async {
        progressTimer = Timer.periodic(const Duration(milliseconds: 30), (
          timer,
        ) {
          samples++;
          process.emitStdout('BSTREAM_PROGRESS| ${samples * 10}.0%|1\n');
          if (samples < 5) {
            return;
          }
          timer.cancel();
          unawaited(() async {
            await output.parent.create(recursive: true);
            await output.writeAsBytes(const [1, 2, 3], flush: true);
            process.completeSuccessfully('${output.path}\n');
          }());
        });
        return process;
      },
      processTerminator: (active) => active.kill(),
    );
    addTearDown(() async {
      progressTimer?.cancel();
      await service.dispose();
    });
    await service.setYtDlpPath(executable.path);

    final result = await service.downloadAudio(
      'https://www.youtube.com/watch?v=abcdefghijk',
      DownloadOptions(outputDirectory: outputDirectory.path),
    );

    expect(result.filePath, output.path);
    expect(samples, 5);
    expect(process.killCalls, 0);
  });

  test('total watchdog wins even while progress keeps arriving', () async {
    final temp = await Directory.systemTemp.createTemp(
      'bstream_ytdlp_total_watchdog_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final executable = File(
      p.join(temp.path, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp'),
    );
    await executable.writeAsString('test executable');
    final process = _ControllableProcess(92004);
    Timer? progressTimer;
    final service = DesktopDownloaderService(
      toolDirectories: const [],
      processResolutionTimeout: const Duration(seconds: 1),
      processIdleTimeout: const Duration(seconds: 1),
      processDownloadTotalTimeout: const Duration(milliseconds: 60),
      processStarter: (_, _) async {
        progressTimer = Timer.periodic(
          const Duration(milliseconds: 10),
          (_) => process.emitStdout('BSTREAM_PROGRESS| 1.0%|1\n'),
        );
        return process;
      },
      processTerminator: (active) => active.kill(),
    );
    addTearDown(() async {
      progressTimer?.cancel();
      await service.dispose();
    });
    await service.setYtDlpPath(executable.path);

    await expectLater(
      service.downloadAudio(
        'https://www.youtube.com/watch?v=abcdefghijk',
        DownloadOptions(outputDirectory: p.join(temp.path, 'audio')),
      ),
      throwsA(
        isA<DownloaderException>().having(
          (error) => error.code,
          'code',
          'yt_dlp_process_total_timeout',
        ),
      ),
    );

    progressTimer?.cancel();
    expect(process.killCalls, 1);
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

class _ControllableProcess implements Process {
  _ControllableProcess(this.pid);

  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exitCode = Completer<int>();

  @override
  final int pid;

  int killCalls = 0;

  void emitStdout(String output) {
    if (!_exitCode.isCompleted) {
      _stdout.add(utf8.encode(output));
    }
  }

  void completeSuccessfully(String output) {
    if (_exitCode.isCompleted) {
      return;
    }
    _stdout.add(utf8.encode(output));
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exitCode.complete(0);
  }

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => throw UnsupportedError('stdin is unused by this test');

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls++;
    if (_exitCode.isCompleted) {
      return false;
    }
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exitCode.complete(-1);
    return true;
  }
}
