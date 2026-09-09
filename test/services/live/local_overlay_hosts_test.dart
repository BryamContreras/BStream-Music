import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/live/local_overlay_hosts.dart';
import 'package:flutter_test/flutter_test.dart';

const _hostsPath = r'C:\Windows\System32\drivers\etc\hosts';
const _powerShell =
    r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
const _managedBlock = '''# BEGIN BStream Music LIVE Overlay
127.0.0.1\toverlay.bstreammusic.test
# END BStream Music LIVE Overlay
''';

void main() {
  group('local LIVE overlay endpoint', () {
    test('uses the stable HTTP port-80 endpoint', () {
      expect(localLiveOverlayHost, 'overlay.bstreammusic.test');
      expect(localLiveOverlayIpv4, '127.0.0.1');
      expect(localLiveOverlayPort, 80);
      expect(localLiveOverlayPath, '/overlay');
      expect(localLiveOverlayUrl, 'http://overlay.bstreammusic.test/overlay');
      expect(
        Uri(
          scheme: 'http',
          host: localLiveOverlayHost,
          port: localLiveOverlayPort,
          path: localLiveOverlayPath,
        ).toString(),
        localLiveOverlayUrl,
      );
    });
  });

  group('inspectLocalOverlayHosts', () {
    test('reports a missing mapping without markers', () {
      final result = inspectLocalOverlayHosts('''
# Copyright
127.0.0.1 localhost
::1 localhost
''');

      expect(result.status, LocalOverlayHostStatus.missing);
      expect(result.isConfigured, isFalse);
      expect(result.isOwned, isFalse);
      expect(result.mappedAddresses, isEmpty);
    });

    test('accepts an external correct entry without claiming ownership', () {
      final result = inspectLocalOverlayHosts('''
127.0.0.1 localhost Overlay.BStreamMusic.Test. another-alias # retained
''');

      expect(result.status, LocalOverlayHostStatus.configured);
      expect(result.isConfigured, isTrue);
      expect(result.isOwned, isFalse);
      expect(result.mappedAddresses, <String>['127.0.0.1']);
    });

    test(
      'recognizes its marked block while tolerating surrounding content',
      () {
        final result = inspectLocalOverlayHosts('''
# user entry before
10.0.0.5 intranet.test
$_managedBlock# user entry after
::1 localhost
''');

        expect(result.status, LocalOverlayHostStatus.configured);
        expect(result.isOwned, isTrue);
        expect(result.mappedAddresses, <String>['127.0.0.1']);
      },
    );

    test('treats any other address as a conflict', () {
      final result = inspectLocalOverlayHosts('''
127.0.0.1 overlay.bstreammusic.test
192.0.2.8 overlay.bstreammusic.test
''');

      expect(result.status, LocalOverlayHostStatus.conflicting);
      expect(result.isConfigured, isFalse);
      expect(result.mappedAddresses, <String>['127.0.0.1', '192.0.2.8']);
    });

    test('reports orphaned or duplicate ownership markers as malformed', () {
      final orphaned = inspectLocalOverlayHosts('''
# BEGIN BStream Music LIVE Overlay
127.0.0.1 localhost
''');
      final duplicate = inspectLocalOverlayHosts('''
# BEGIN BStream Music LIVE Overlay
# BEGIN BStream Music LIVE Overlay
# END BStream Music LIVE Overlay
''');

      expect(orphaned.status, LocalOverlayHostStatus.malformed);
      expect(duplicate.status, LocalOverlayHostStatus.malformed);
    });

    test('prioritizes malformed ownership over a correct external entry', () {
      final orphaned = inspectLocalOverlayHosts('''
127.0.0.1 overlay.bstreammusic.test
# BEGIN BStream Music LIVE Overlay
127.0.0.1 localhost
''');
      final emptyBlock = inspectLocalOverlayHosts('''
127.0.0.1 overlay.bstreammusic.test
# BEGIN BStream Music LIVE Overlay
127.0.0.1 localhost
# END BStream Music LIVE Overlay
''');

      expect(orphaned.status, LocalOverlayHostStatus.malformed);
      expect(emptyBlock.status, LocalOverlayHostStatus.malformed);
    });
  });

  group('WindowsLocalOverlayHostProvisioner', () {
    test('the system runner executes a multiline command argument', () async {
      if (!Platform.isWindows) return;

      final systemRoot = Platform.environment['SystemRoot'];
      expect(systemRoot, isNotNull);
      final executable =
          '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      const script = r'''
function Write-BStreamProbe {
  [Console]::Out.Write('bstream-command-ok')
}
Write-BStreamProbe
''';
      final result = await const SystemLocalOverlayHostsCommandRunner().run(
        executable,
        const <String>[
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          script,
        ],
      );

      expect(result.exitCode, 0);
      expect(result.stdout, 'bstream-command-ok');
      expect(result.stderr, isEmpty);
    });

    test('the system runner accepts a production-sized raw command', () async {
      if (!Platform.isWindows) return;

      final systemRoot = Platform.environment['SystemRoot'];
      expect(systemRoot, isNotNull);
      final executable =
          '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      final padding = List<String>.filled(19000, 'x').join();
      final script =
          "\$value = '$padding'\n[Console]::Out.Write(\$value.Length)";
      final result = await const SystemLocalOverlayHostsCommandRunner().run(
        executable,
        <String>[
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          script,
        ],
      );

      expect(script.length, greaterThan(19000));
      expect(result.exitCode, 0);
      expect(result.stdout, '19000');
      expect(result.stderr, isEmpty);
    });

    test(
      'the system runner propagates an explicit multiline script exit code',
      () async {
        if (!Platform.isWindows) return;

        final systemRoot = Platform.environment['SystemRoot'];
        expect(systemRoot, isNotNull);
        final executable =
            '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
        const script = r'''
$powerShell = Join-Path $PSHOME 'powershell.exe'
$process = Start-Process `
  -FilePath $powerShell `
  -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 23'
  ) `
  -Wait `
  -PassThru
exit $process.ExitCode
''';
        final result = await const SystemLocalOverlayHostsCommandRunner().run(
          executable,
          const <String>[
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            script,
          ],
        );

        expect(result.exitCode, 23);
      },
    );

    test(
      'the system runner kills a command that exceeds its deadline',
      () async {
        final process = _FakeLocalOverlayHostsProcess(pid: 4112);
        final runner = SystemLocalOverlayHostsCommandRunner(
          processStarter: (_, _) async => process,
        );

        await expectLater(
          runner.run(_powerShell, const <String>[
            '-Command',
            'never-completes',
          ], timeout: const Duration(milliseconds: 15)),
          throwsA(
            isA<LocalOverlayHostsCommandTimeoutException>()
                .having((error) => error.pid, 'pid', 4112)
                .having(
                  (error) => error.timeout,
                  'timeout',
                  const Duration(milliseconds: 15),
                ),
          ),
        );

        expect(process.killCalls, 1);
        expect(process.standardInputClosed, isTrue);
      },
    );

    test('kills a process that starts after the start deadline', () async {
      final process = _FakeLocalOverlayHostsProcess(pid: 4113);
      final start = Completer<LocalOverlayHostsProcess>();
      final runner = SystemLocalOverlayHostsCommandRunner(
        processStarter: (_, _) => start.future,
      );

      await expectLater(
        runner.run(_powerShell, const <String>[
          '-Command',
          'delayed-start',
        ], timeout: const Duration(milliseconds: 10)),
        throwsA(
          isA<LocalOverlayHostsCommandTimeoutException>().having(
            (error) => error.pid,
            'pid',
            isNull,
          ),
        ),
      );

      start.complete(process);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(process.killCalls, 1);
      expect(process.standardInputClosed, isTrue);
    });

    test('rejects an oversized Windows command before starting it', () async {
      var starts = 0;
      final runner = SystemLocalOverlayHostsCommandRunner(
        processStarter: (_, _) async {
          starts++;
          return _FakeLocalOverlayHostsProcess(pid: 4114);
        },
      );
      final oversized = List<String>.filled(33000, 'x').join();

      await expectLater(
        runner.run(_powerShell, <String>['-Command', oversized]),
        throwsA(
          isA<LocalOverlayHostsCommandLineException>().having(
            (error) => error.estimatedLength,
            'estimatedLength',
            greaterThan(32767),
          ),
        ),
      );
      expect(starts, 0);
    });

    test('does not inspect files or launch a command outside Windows', () {
      var pathReads = 0;
      final runner = _FakeCommandRunner((_, _) async {
        fail('PowerShell must not be launched outside Windows.');
      });
      final provisioner = WindowsLocalOverlayHostProvisioner(
        commandRunner: runner,
        hostsReader: (_) async => fail('The hosts file must not be read.'),
        hostsPathProvider: () {
          pathReads++;
          return _hostsPath;
        },
        isWindows: false,
      );

      expect(provisioner.ensureConfigured, throwsUnsupportedError);
      expect(pathReads, 0);
      expect(runner.calls, 0);
    });

    test('does not request UAC for an existing external mapping', () async {
      var reads = 0;
      final runner = _FakeCommandRunner((_, _) async {
        fail('A correct external mapping must not request elevation.');
      });
      final provisioner = WindowsLocalOverlayHostProvisioner(
        commandRunner: runner,
        hostsReader: (path) async {
          reads++;
          expect(path, _hostsPath);
          return '127.0.0.1 overlay.bstreammusic.test\r\n';
        },
        hostsPathProvider: () => _hostsPath,
        powerShellExecutable: _powerShell,
        isWindows: true,
      );

      await provisioner.ensureConfigured();

      expect(reads, 1);
      expect(runner.calls, 0);
    });

    test('rejects a conflicting address without modifying it', () async {
      final runner = _FakeCommandRunner((_, _) async {
        fail('A conflicting hosts entry must not be overwritten.');
      });
      final provisioner = WindowsLocalOverlayHostProvisioner(
        commandRunner: runner,
        hostsReader: (_) async => '203.0.113.7 overlay.bstreammusic.test\r\n',
        hostsPathProvider: () => _hostsPath,
        powerShellExecutable: _powerShell,
        isWindows: true,
      );

      await expectLater(
        provisioner.ensureConfigured(),
        throwsA(
          isA<LocalOverlayHostsConflictException>()
              .having(
                (error) => error.message,
                'message',
                contains(localLiveOverlayHost),
              )
              .having(
                (error) => error.message,
                'message',
                contains('203.0.113.7'),
              ),
        ),
      );
      expect(runner.calls, 0);
    });

    test(
      'launches one encoded elevated update, preserves content, flushes and verifies',
      () async {
        var contents = '''# existing user entries\r\n
127.0.0.1 localhost\r\n
10.1.2.3 intranet.example\r\n
''';
        var reads = 0;
        var pathReads = 0;
        late String launcher;
        late String elevatedScript;
        late List<String> launcherArguments;
        late final _FakeCommandRunner runner;
        runner = _FakeCommandRunner((executable, arguments) async {
          expect(executable, _powerShell);
          launcherArguments = arguments;
          expect(
            arguments,
            containsAllInOrder(<String>[
              '-NoLogo',
              '-NoProfile',
              '-WindowStyle',
              'Hidden',
              '-NonInteractive',
              '-ExecutionPolicy',
              'Bypass',
              '-Command',
            ]),
          );
          launcher = arguments.last;
          final innerMatch = RegExp(
            r"\$innerCommand = '([^']+)'",
          ).firstMatch(launcher);
          expect(innerMatch, isNotNull);
          elevatedScript = _decodePowerShell(innerMatch!.group(1)!);

          expect(contents, contains('# existing user entries'));
          contents = '$contents$_managedBlock';
          return ProcessResult(42, 0, '', '');
        });
        final provisioner = WindowsLocalOverlayHostProvisioner(
          commandRunner: runner,
          hostsReader: (path) async {
            reads++;
            expect(path, _hostsPath);
            return contents;
          },
          hostsPathProvider: () {
            pathReads++;
            return _hostsPath;
          },
          powerShellExecutable: _powerShell,
          isWindows: true,
        );

        await provisioner.ensureConfigured();

        expect(runner.calls, 1);
        expect(reads, 2);
        expect(pathReads, 1);
        expect(launcher, contains('Start-Process'));
        expect(launcher, contains('-Verb RunAs'));
        expect(launcher, isNot(contains('    -Wait `')));
        expect(launcher, contains('-PassThru'));
        expect(launcher, contains(r'$timeoutMilliseconds = 25000'));
        expect(
          launcher,
          contains(r'$process.WaitForExit($timeoutMilliseconds)'),
        );
        expect(launcher, contains(r'try { $process.Kill() }'));
        expect(launcher, contains('exit 124'));
        expect(launcher, contains(r"Join-Path $PSHOME 'powershell.exe'"));
        expect(runner.lastTimeout, localOverlayHostsCommandTimeout);
        expect(
          launcherArguments.join(' ').length,
          lessThan(32767),
          reason:
              'The launcher is passed directly to -Command and must remain '
              'below the Windows command-line limit.',
        );
        expect(elevatedScript, contains(r'$hostsPath = '));
        expect(elevatedScript, contains(_hostsPath));
        expect(elevatedScript, contains(localLiveOverlayHost));
        expect(elevatedScript, contains(localLiveOverlayIpv4));
        expect(elevatedScript, contains('# BEGIN BStream Music LIVE Overlay'));
        expect(elevatedScript, contains('# END BStream Music LIVE Overlay'));
        expect(
          elevatedScript,
          contains(r'$encoding.GetBytes($separator + $block)'),
        );
        expect(
          elevatedScript,
          contains(r'[System.Array]::Copy($originalBytes'),
        );
        expect(elevatedScript, contains('[System.IO.File]::Replace'));
        expect(elevatedScript, contains('Get-Acl -LiteralPath'));
        expect(elevatedScript, contains('Set-Acl -LiteralPath'));
        expect(elevatedScript, contains('UTF-32 Windows hosts file'));
        expect(elevatedScript, contains('ambiguous encoding'));
        expect(
          elevatedScript,
          contains(
            r"$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'",
          ),
        );
        expect(elevatedScript, contains('exit 125'));
        expect(elevatedScript, contains('SHA256'));
        expect(elevatedScript, contains(r'System32\ipconfig.exe'));
        expect(elevatedScript, contains('/flushdns'));
        expect(
          elevatedScript,
          isNot(contains('ipconfig /flushdns failed')),
          reason:
              'A blocked cache flush must not roll back a verified hosts entry.',
        );
        expect(elevatedScript, contains(r'if ($failedHash -eq $updatedHash)'));
        expect(contents, contains('10.1.2.3 intranet.example'));

        await provisioner.ensureConfigured();

        expect(runner.calls, 1, reason: 'The verified mapping is idempotent.');
        expect(reads, 3);
        expect(pathReads, 2);
      },
    );

    test(
      'fails if elevation reports success but verification does not',
      () async {
        var reads = 0;
        final runner = _FakeCommandRunner(
          (_, _) async => ProcessResult(9, 0, '', ''),
        );
        final provisioner = WindowsLocalOverlayHostProvisioner(
          commandRunner: runner,
          hostsReader: (_) async {
            reads++;
            return '127.0.0.1 localhost\r\n';
          },
          hostsPathProvider: () => _hostsPath,
          powerShellExecutable: _powerShell,
          isWindows: true,
        );

        await expectLater(
          provisioner.ensureConfigured(),
          throwsA(isA<LocalOverlayHostsVerificationException>()),
        );
        expect(runner.calls, 1);
        expect(reads, 2);
      },
    );

    test('surfaces a rejected UAC prompt without a second attempt', () async {
      final runner = _FakeCommandRunner(
        (_, _) async => ProcessResult(13, 1223, '', 'Operation canceled'),
      );
      final provisioner = WindowsLocalOverlayHostProvisioner(
        commandRunner: runner,
        hostsReader: (_) async => '127.0.0.1 localhost\r\n',
        hostsPathProvider: () => _hostsPath,
        powerShellExecutable: _powerShell,
        isWindows: true,
      );

      await expectLater(
        provisioner.ensureConfigured(),
        throwsA(
          isA<LocalOverlayHostsElevationCancelledException>().having(
            (error) => error.message,
            'message',
            contains('permission request was cancelled'),
          ),
        ),
      );
      expect(runner.calls, 1);
    });

    test('reports an application-control policy block distinctly', () async {
      final runner = _FakeCommandRunner(
        (_, _) async => ProcessResult(14, 125, '', ''),
      );
      final provisioner = WindowsLocalOverlayHostProvisioner(
        commandRunner: runner,
        hostsReader: (_) async => '127.0.0.1 localhost\r\n',
        hostsPathProvider: () => _hostsPath,
        powerShellExecutable: _powerShell,
        isWindows: true,
      );

      await expectLater(
        provisioner.ensureConfigured(),
        throwsA(
          isA<LocalOverlayHostsPolicyException>().having(
            (error) => error.message,
            'message',
            contains('application-control policy'),
          ),
        ),
      );
      expect(runner.calls, 1);
    });

    test('surfaces and clears a timed-out permission request', () async {
      const timeout = Duration(milliseconds: 25);
      final runner = _FakeCommandRunner((_, _) async {
        throw const LocalOverlayHostsCommandTimeoutException(
          timeout: timeout,
          pid: 5120,
        );
      });
      final provisioner = WindowsLocalOverlayHostProvisioner(
        commandRunner: runner,
        hostsReader: (_) async => '127.0.0.1 localhost\r\n',
        hostsPathProvider: () => _hostsPath,
        powerShellExecutable: _powerShell,
        commandTimeout: timeout,
        isWindows: true,
      );

      Future<void> expectTimeout() => expectLater(
        provisioner.ensureConfigured(),
        throwsA(
          isA<LocalOverlayHostsTimeoutException>()
              .having(
                (error) => error.message,
                'message',
                contains('25 milliseconds'),
              )
              .having(
                (error) => error.cause,
                'cause',
                isA<LocalOverlayHostsCommandTimeoutException>(),
              ),
        ),
      );

      await expectTimeout();
      await expectTimeout();

      expect(
        runner.calls,
        2,
        reason: 'A timeout must clear the coalesced run.',
      );
      expect(runner.lastTimeout, timeout);
    });

    test('coalesces concurrent callers into one elevation', () async {
      var contents = '127.0.0.1 localhost\r\n';
      final commandStarted = Completer<void>();
      final allowCommandToFinish = Completer<void>();
      final runner = _FakeCommandRunner((_, _) async {
        commandStarted.complete();
        await allowCommandToFinish.future;
        contents = '$contents$_managedBlock';
        return ProcessResult(77, 0, '', '');
      });
      final provisioner = WindowsLocalOverlayHostProvisioner(
        commandRunner: runner,
        hostsReader: (_) async => contents,
        hostsPathProvider: () => _hostsPath,
        powerShellExecutable: _powerShell,
        isWindows: true,
      );

      final first = provisioner.ensureConfigured();
      final second = provisioner.ensureConfigured();
      expect(identical(first, second), isTrue);
      await commandStarted.future;
      expect(runner.calls, 1);

      allowCommandToFinish.complete();
      await Future.wait<void>(<Future<void>>[first, second]);

      expect(runner.calls, 1);
    });

    test('rejects non-absolute paths before launching PowerShell', () async {
      final runner = _FakeCommandRunner((_, _) async {
        fail('An unsafe path must not be passed to PowerShell.');
      });
      final provisioner = WindowsLocalOverlayHostProvisioner(
        commandRunner: runner,
        hostsReader: (_) async => '127.0.0.1 localhost\r\n',
        hostsPathProvider: () => r'.\drivers\etc\hosts',
        powerShellExecutable: _powerShell,
        isWindows: true,
      );

      await expectLater(
        provisioner.ensureConfigured(),
        throwsA(isA<LocalOverlayHostsException>()),
      );
      expect(runner.calls, 0);
    });
  });
}

String _decodePowerShell(String encoded) {
  final bytes = base64Decode(encoded);
  final codeUnits = <int>[];
  for (var index = 0; index + 1 < bytes.length; index += 2) {
    codeUnits.add(bytes[index] | (bytes[index + 1] << 8));
  }
  return String.fromCharCodes(codeUnits);
}

final class _FakeCommandRunner implements LocalOverlayHostsCommandRunner {
  _FakeCommandRunner(this.callback);

  final Future<ProcessResult> Function(String, List<String>) callback;
  int calls = 0;
  Duration? lastTimeout;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = localOverlayHostsCommandTimeout,
  }) {
    calls++;
    lastTimeout = timeout;
    return callback(executable, arguments);
  }
}

final class _FakeLocalOverlayHostsProcess implements LocalOverlayHostsProcess {
  _FakeLocalOverlayHostsProcess({required this.pid});

  @override
  final int pid;

  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exitCode = Completer<int>();
  var killCalls = 0;
  var standardInputClosed = false;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> closeStandardInput() async {
    standardInputClosed = true;
  }

  @override
  bool kill() {
    killCalls++;
    if (!_exitCode.isCompleted) _exitCode.complete(-1);
    if (!_stdout.isClosed) unawaited(_stdout.close());
    if (!_stderr.isClosed) unawaited(_stderr.close());
    return true;
  }
}
