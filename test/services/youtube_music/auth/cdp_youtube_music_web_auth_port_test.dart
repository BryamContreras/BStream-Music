import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/youtube_music/auth/cdp_youtube_music_web_auth_port.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_web_auth_port.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChromiumExecutableLocator', () {
    test('finds Edge, Chrome, Brave, and Chromium on Linux PATH', () {
      final existing = <String>{'/opt/browsers/brave-browser'};
      final locator = ChromiumExecutableLocator(
        environment: const <String, String>{
          'PATH': '/usr/local/bin:/opt/browsers',
        },
        fileExists: existing.contains,
      );

      expect(
        locator.locate(DesktopOperatingSystem.linux),
        '/opt/browsers/brave-browser',
      );
      final candidates = locator.candidates(DesktopOperatingSystem.linux);
      expect(candidates, contains('/opt/browsers/microsoft-edge'));
      expect(candidates, contains('/opt/browsers/google-chrome'));
      expect(candidates, contains('/opt/browsers/brave-browser'));
      expect(candidates, contains('/opt/browsers/chromium'));
    });

    test('searches standard Windows installation roots and PATH', () {
      const edge =
          r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe';
      final locator = ChromiumExecutableLocator(
        environment: const <String, String>{
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
          'ProgramFiles': r'C:\Program Files',
          'LocalAppData': r'C:\Users\test\AppData\Local',
          'Path': r'D:\Portable\Browser',
        },
        fileExists: (value) => value == edge,
      );

      expect(locator.locate(DesktopOperatingSystem.windows), edge);
      final candidates = locator.candidates(DesktopOperatingSystem.windows);
      expect(candidates, contains(r'D:\Portable\Browser\brave.exe'));
      expect(
        candidates,
        contains(r'C:\Program Files\Google\Chrome\Application\chrome.exe'),
      );
      expect(
        candidates,
        contains(
          r'C:\Users\test\AppData\Local\Chromium\Application\chrome.exe',
        ),
      );
    });
  });

  test('orphan recovery deletes only marked inactive profiles', () async {
    final root = await Directory.systemTemp.createTemp(
      'bstream_cdp_collector_test_',
    );
    Future<Directory> profile(String suffix, {bool marked = true}) async {
      final directory = Directory(
        '${root.path}${Platform.pathSeparator}'
        '${CdpOrphanedProfileCollector.profilePrefix}$suffix',
      );
      await directory.create();
      if (marked) {
        await File(
          '${directory.path}${Platform.pathSeparator}'
          '${CdpOrphanedProfileCollector.profileMarker}',
        ).writeAsString(
          CdpOrphanedProfileCollector.markerDocument(
            createdAt: DateTime.utc(2025),
            processId: suffix == 'active_pid' ? 333 : 111,
            debugPort: suffix == 'active_port' ? 2222 : 1111,
          ),
        );
      }
      return directory;
    }

    final orphan = await profile('orphan');
    final activeLock = await profile('active_lock');
    final activePort = await profile('active_port');
    final activePid = await profile('active_pid');
    final unmarked = await profile('unmarked', marked: false);
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final collector = CdpOrphanedProfileCollector(
      temporaryRoot: root,
      debugPortProbe: (port) async => port == 2222,
      processProbe: (processId, _) => processId == 333,
      // POSIX advisory locks are process-scoped, so a second file descriptor
      // in this test process can reacquire its own lock. Inject the same
      // in-use decision while production retains the real cross-process lock.
      profileInUseProbe: (profile) async => profile.path == activeLock.path,
    );

    expect(await collector.collect(DesktopOperatingSystem.linux), 1);
    expect(await orphan.exists(), isFalse);
    expect(await activeLock.exists(), isTrue);
    expect(await activePort.exists(), isTrue);
    expect(await activePid.exists(), isTrue);
    expect(await unmarked.exists(), isTrue);
  });

  test('an unsupported platform never invokes the desktop launcher', () async {
    final fixture = _Fixture(
      operatingSystem: DesktopOperatingSystem.unsupported,
    );

    await expectLater(
      fixture.port.prepare(),
      throwsA(isA<YouTubeMusicWebAuthException>()),
    );

    expect(fixture.launcher.launchCalls, 0);
    await fixture.port.cleanup();
  });

  test('prepare connects CDP, intercepts documents, and opens login', () async {
    final fixture = _Fixture();

    await fixture.port.prepare();

    expect(fixture.launcher.launchCalls, 1);
    expect(fixture.connector.connectCalls, 1);
    expect(
      fixture.connection.methods,
      containsAllInOrder(<String>[
        'Page.enable',
        'Runtime.enable',
        'Network.enable',
        'Fetch.enable',
        'Page.getFrameTree',
        'Page.navigate',
      ]),
    );
    expect(fixture.port.isPrepared, isTrue);
    expect(fixture.port.currentUri, isNull);
    final fetchEnable = fixture.connection.command('Fetch.enable');
    expect(fetchEnable.params['patterns'], isNotEmpty);

    await fixture.port.cleanup();
  });

  test('prepare fails closed when CDP omits the main frame id', () async {
    final fixture = _Fixture();
    fixture.connection.frameTree = const <String, Object?>{
      'frameTree': <String, Object?>{
        'frame': <String, Object?>{'url': 'about:blank'},
      },
    };
    var browserClosedEvents = 0;
    final subscription = fixture.port.browserClosedStream.listen(
      (_) => browserClosedEvents += 1,
    );

    await expectLater(
      fixture.port.prepare(),
      throwsA(isA<YouTubeMusicWebAuthException>()),
    );

    expect(fixture.connection.methods, isNot(contains('Page.navigate')));
    expect(fixture.session.deleteCalls, 1);
    expect(browserClosedEvents, 0);
    await subscription.cancel();
    await fixture.port.cleanup();
  });

  test('Fetch policy blocks only unsafe main-frame documents', () async {
    final fixture = _Fixture();
    await fixture.port.prepare();

    fixture.connection.emit(
      const CdpEvent('Fetch.requestPaused', <String, Object?>{
        'requestId': 'unsafe-main',
        'resourceType': 'Document',
        'frameId': 'main-frame',
        'request': <String, Object?>{'url': 'https://evil.example/login'},
      }),
    );
    fixture.connection.emit(
      const CdpEvent('Fetch.requestPaused', <String, Object?>{
        'requestId': 'unknown-https-frame',
        'resourceType': 'Document',
        'frameId': 'unknown-frame',
        'request': <String, Object?>{'url': 'https://cdn.example/frame'},
      }),
    );
    fixture.connection.emit(
      const CdpEvent('Fetch.requestPaused', <String, Object?>{
        'requestId': 'insecure-subframe',
        'resourceType': 'Document',
        'frameId': 'child-frame',
        'request': <String, Object?>{'url': 'http://cdn.example/frame'},
      }),
    );
    fixture.connection.emit(
      const CdpEvent('Fetch.requestPaused', <String, Object?>{
        'requestId': 'google-main',
        'resourceType': 'Document',
        'frameId': 'main-frame',
        'request': <String, Object?>{
          'url': 'https://accounts.google.com/ServiceLogin',
        },
      }),
    );
    fixture.connection.emit(
      const CdpEvent('Fetch.requestPaused', <String, Object?>{
        'requestId': 'third-party-subframe',
        'resourceType': 'Document',
        'frameId': 'child-frame',
        'request': <String, Object?>{'url': 'https://cdn.example/frame'},
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      fixture.connection.commandForRequest('unsafe-main').method,
      'Fetch.failRequest',
    );
    expect(
      fixture.connection.commandForRequest('unsafe-main').params['errorReason'],
      'BlockedByClient',
    );
    expect(
      fixture.connection.commandForRequest('google-main').method,
      'Fetch.continueRequest',
    );
    expect(
      fixture.connection.commandForRequest('third-party-subframe').method,
      'Fetch.continueRequest',
    );
    expect(
      fixture.connection.commandForRequest('insecure-subframe').method,
      'Fetch.failRequest',
    );
    expect(
      fixture.connection.commandForRequest('unknown-https-frame').method,
      'Fetch.failRequest',
    );

    await fixture.port.cleanup();
  });

  test('publishes only main-frame navigation and browser closure', () async {
    final fixture = _Fixture();
    await fixture.port.prepare();
    final navigation = fixture.port.navigationStream.first;

    fixture.connection.emit(
      const CdpEvent('Page.frameNavigated', <String, Object?>{
        'frame': <String, Object?>{
          'id': 'child-frame',
          'parentId': 'main-frame',
          'url': 'https://cdn.example/frame',
        },
      }),
    );
    fixture.connection.emit(
      const CdpEvent('Page.frameNavigated', <String, Object?>{
        'frame': <String, Object?>{
          'id': 'main-frame',
          'url': 'https://music.youtube.com/',
        },
      }),
    );

    expect(await navigation, Uri.parse('https://music.youtube.com/'));

    final closed = fixture.port.browserClosedStream.first;
    fixture.session.completeBrowserClosed();
    await closed;
    await Future<void>.delayed(Duration.zero);
    expect(fixture.port.isPrepared, isFalse);
    expect(fixture.session.deleteCalls, 1);
  });

  test(
    'target closure invalidates and cleans while process remains open',
    () async {
      final fixture = _Fixture();
      await fixture.port.prepare();
      final closedEvents = fixture.port.browserClosedStream.toList();

      fixture.connection.completeTargetClosed();
      final events = await closedEvents;

      expect(events, hasLength(1));
      expect(fixture.port.isPrepared, isFalse);
      expect(fixture.session.closeCalls, 1);
      expect(fixture.session.deleteCalls, 1);
    },
  );

  test('cleanup interrupts a CDP command that never completes', () async {
    final fixture = _Fixture(commandTimeout: const Duration(milliseconds: 50));
    fixture.connection.hangingMethod = 'Page.enable';
    final preparation = expectLater(
      fixture.port.prepare(),
      throwsA(isA<YouTubeMusicWebAuthException>()),
    );
    while (!fixture.connection.methods.contains('Page.enable')) {
      await Future<void>.delayed(Duration.zero);
    }

    final stopwatch = Stopwatch()..start();
    final cleanup = await fixture.port.cleanup();
    stopwatch.stop();

    expect(cleanup.completed, isTrue);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(fixture.session.deleteCalls, 1);
    await preparation;
  });

  test(
    'a runtime command timeout closes the target and stops retries',
    () async {
      final fixture = _Fixture(
        commandTimeout: const Duration(milliseconds: 50),
      );
      await fixture.port.prepare();
      fixture.connection.history = <String, Object?>{
        'currentIndex': 0,
        'entries': <Object?>[
          <String, Object?>{'id': 9, 'url': 'https://music.youtube.com/'},
        ],
      };
      fixture.connection.hangingMethod = 'Runtime.evaluate';
      final browserClosed = fixture.port.browserClosedStream.first;
      final stopwatch = Stopwatch()..start();

      await expectLater(
        fixture.port.waitForAuthenticatedSession(
          maximumAttempts: 20,
          retryDelay: Duration.zero,
        ),
        throwsA(isA<YouTubeMusicWebAuthException>()),
      );
      await browserClosed;
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(
        fixture.connection.methods
            .where((method) => method == 'Runtime.evaluate')
            .length,
        1,
      );
      expect(fixture.session.deleteCalls, 1);
    },
  );

  test('extracts WEB_REMIX data and only YouTube HttpOnly cookies', () async {
    final fixture = _Fixture();
    await fixture.port.prepare();
    fixture.connection.history = <String, Object?>{
      'currentIndex': 0,
      'entries': <Object?>[
        <String, Object?>{'id': 9, 'url': 'https://music.youtube.com/'},
      ],
    };
    fixture.connection.configuration = <String, Object?>{
      'visitorData': 'visitor-data',
      'dataSyncId': 'channel-id||transport-suffix',
      'authUser': '3',
      'delegatedPageId': 'page-id',
      'apiKey': 'test_api_key',
      'clientVersion': '1.20260827.01.00',
      'clientName': 'WEB_REMIX',
      'region': 'NI',
    };
    fixture.connection.cookies = <Object?>[
      <String, Object?>{
        'name': 'SAPISID',
        'value': 'signing-secret',
        'domain': '.youtube.com',
        'secure': true,
        'httpOnly': true,
      },
      <String, Object?>{
        'name': 'VISITOR_INFO1_LIVE',
        'value': 'visitor-cookie',
        'domain': 'music.youtube.com',
        'secure': true,
        'httpOnly': true,
      },
      <String, Object?>{
        'name': 'SID',
        'value': 'google-secret-must-not-leak',
        'domain': '.google.com',
        'secure': true,
        'httpOnly': true,
      },
      <String, Object?>{
        'name': 'EVIL',
        'value': 'lookalike-secret-must-not-leak',
        'domain': '.youtube.com.evil.example',
        'secure': true,
      },
    ];

    final auth = await fixture.port.waitForAuthenticatedSession(
      maximumAttempts: 1,
      retryDelay: Duration.zero,
    );

    expect(
      auth.cookieHeader,
      'SAPISID=signing-secret; VISITOR_INFO1_LIVE=visitor-cookie',
    );
    expect(auth.cookieHeader, isNot(contains('google-secret')));
    expect(auth.cookieHeader, isNot(contains('lookalike-secret')));
    expect(auth.identity.visitorData, 'visitor-data');
    expect(auth.identity.authUser, '3');
    expect(auth.identity.dataSyncId, 'channel-id');
    expect(auth.identity.delegatedPageId, 'page-id');
    expect(auth.clientName, 'WEB_REMIX');
    expect(auth.region, 'NI');

    await fixture.port.cleanup();
  });

  test('minimizes and restores the owned browser window via CDP', () async {
    final fixture = _Fixture();
    await fixture.port.prepare();

    fixture.connection.windowState = 'normal';
    await fixture.port.minimize();
    expect(
      fixture.connection.commands.last.params['bounds'],
      const <String, Object?>{'windowState': 'minimized'},
    );

    fixture.connection.windowState = 'minimized';
    await fixture.port.bringToForeground();
    expect(
      fixture.connection.commands
          .where((entry) => entry.method == 'Browser.setWindowBounds')
          .last
          .params['bounds'],
      const <String, Object?>{'windowState': 'normal'},
    );
    expect(fixture.connection.commands.last.method, 'Page.bringToFront');

    await fixture.port.cleanup();
  });

  test('cleanup retries deletion of only the launcher-owned profile', () async {
    final fixture = _Fixture(deleteResults: <bool>[false, true]);
    await fixture.port.prepare();

    final first = await fixture.port.cleanup();
    expect(first.completed, isFalse);
    expect(fixture.session.closeCalls, 1);
    expect(fixture.session.deleteCalls, 1);

    final second = await fixture.port.cleanup();
    expect(second.completed, isTrue);
    expect(fixture.session.deleteCalls, 2);

    final alreadyClean = await fixture.port.cleanup();
    expect(alreadyClean.completed, isTrue);
    expect(fixture.session.deleteCalls, 2);
  });

  test('prepare retry never overwrites an undeleted prior profile', () async {
    final fixture = _Fixture(
      deleteResults: <bool>[false, false, true],
      connectorFailures: 1,
    );

    await expectLater(
      fixture.port.prepare(),
      throwsA(isA<YouTubeMusicWebAuthException>()),
    );
    expect(fixture.launcher.launchCalls, 1);
    expect(fixture.session.deleteCalls, 1);

    await expectLater(
      fixture.port.prepare(),
      throwsA(isA<YouTubeMusicWebAuthException>()),
    );
    expect(fixture.launcher.launchCalls, 1);
    expect(fixture.session.deleteCalls, 2);

    expect((await fixture.port.cleanup()).completed, isTrue);
    expect(fixture.session.deleteCalls, 3);
  });
}

class _Fixture {
  _Fixture({
    DesktopOperatingSystem operatingSystem = DesktopOperatingSystem.linux,
    List<bool> deleteResults = const <bool>[true],
    int connectorFailures = 0,
    Duration commandTimeout = const Duration(seconds: 5),
  }) : session = _FakeBrowserSession(deleteResults),
       connection = _FakeCdpConnection() {
    launcher = _FakeBrowserLauncher(session);
    connector = _FakeCdpConnector(
      connection,
      failuresRemaining: connectorFailures,
    );
    port = CdpYouTubeMusicWebAuthPort(
      operatingSystem: operatingSystem,
      browserLauncher: launcher,
      targetConnector: connector,
      commandTimeout: commandTimeout,
    );
  }

  final _FakeBrowserSession session;
  final _FakeCdpConnection connection;
  late final _FakeBrowserLauncher launcher;
  late final _FakeCdpConnector connector;
  late final CdpYouTubeMusicWebAuthPort port;
}

class _FakeBrowserLauncher implements CdpBrowserLauncher {
  _FakeBrowserLauncher(this.session);

  final _FakeBrowserSession session;
  var launchCalls = 0;

  @override
  Future<CdpBrowserSession> launch({
    required DesktopOperatingSystem operatingSystem,
    required Duration startupTimeout,
  }) async {
    launchCalls += 1;
    return session;
  }
}

class _FakeBrowserSession implements CdpBrowserSession {
  _FakeBrowserSession(List<bool> deleteResults)
    : _deleteResults = List<bool>.of(deleteResults);

  final List<bool> _deleteResults;
  final _closed = Completer<void>();
  var closeCalls = 0;
  var deleteCalls = 0;

  @override
  Uri get devToolsHttpEndpoint => Uri.parse('http://127.0.0.1:34567');

  @override
  Future<void> get closed => _closed.future;

  void completeBrowserClosed() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> close() async {
    closeCalls += 1;
    completeBrowserClosed();
  }

  @override
  Future<bool> deleteTemporaryProfile() async {
    deleteCalls += 1;
    if (_deleteResults.isEmpty) return true;
    return _deleteResults.removeAt(0);
  }
}

class _FakeCdpConnector implements CdpTargetConnector {
  _FakeCdpConnector(this.connection, {this.failuresRemaining = 0});

  final _FakeCdpConnection connection;
  var connectCalls = 0;
  var failuresRemaining = 0;

  @override
  Future<CdpTargetConnection> connect({
    required Uri devToolsHttpEndpoint,
    required Duration timeout,
  }) async {
    connectCalls += 1;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw StateError('simulated CDP startup failure');
    }
    return connection;
  }
}

class _CdpCommand {
  const _CdpCommand(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
}

class _FakeCdpConnection implements CdpTargetConnection {
  final _events = StreamController<CdpEvent>.broadcast(sync: true);
  final _closed = Completer<void>();
  final commands = <_CdpCommand>[];
  Map<String, Object?> history = <String, Object?>{
    'currentIndex': 0,
    'entries': <Object?>[
      <String, Object?>{'id': 1, 'url': 'about:blank'},
    ],
  };
  Map<String, Object?> configuration = const <String, Object?>{};
  List<Object?> cookies = const <Object?>[];
  String windowState = 'normal';
  String? hangingMethod;
  Map<String, Object?> frameTree = const <String, Object?>{
    'frameTree': <String, Object?>{
      'frame': <String, Object?>{'id': 'main-frame', 'url': 'about:blank'},
      'childFrames': <Object?>[
        <String, Object?>{
          'frame': <String, Object?>{
            'id': 'child-frame',
            'parentId': 'main-frame',
            'url': 'about:blank',
          },
        },
      ],
    },
  };

  List<String> get methods => commands.map((entry) => entry.method).toList();

  _CdpCommand command(String method) =>
      commands.firstWhere((entry) => entry.method == method);

  _CdpCommand commandForRequest(String requestId) =>
      commands.lastWhere((entry) => entry.params['requestId'] == requestId);

  void emit(CdpEvent event) => _events.add(event);

  void completeTargetClosed() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  String get targetId => 'target-id';

  @override
  Stream<CdpEvent> get events => _events.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<Map<String, Object?>> send(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) async {
    commands.add(_CdpCommand(method, params));
    if (method == hangingMethod) {
      return Completer<Map<String, Object?>>().future;
    }
    return switch (method) {
      'Page.getFrameTree' => frameTree,
      'Page.navigate' => const <String, Object?>{'frameId': 'main-frame'},
      'Page.getNavigationHistory' => history,
      'Runtime.evaluate' => <String, Object?>{
        'result': <String, Object?>{
          'type': 'string',
          'value': jsonEncode(configuration),
        },
      },
      'Network.getCookies' => <String, Object?>{'cookies': cookies},
      'Browser.getWindowForTarget' => <String, Object?>{
        'windowId': 12,
        'bounds': <String, Object?>{'windowState': windowState},
      },
      _ => const <String, Object?>{},
    };
  }

  @override
  Future<void> close() async {
    completeTargetClosed();
    if (!_events.isClosed) await _events.close();
  }
}
