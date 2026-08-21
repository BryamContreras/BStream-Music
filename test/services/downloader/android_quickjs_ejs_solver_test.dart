import 'package:bstream_music/platform_channels/android_ytdl_channel.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/android_quickjs_ejs_solver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('caches the EJS prelude and wraps the call for QuickJS', () async {
    const methodChannel = MethodChannel('test/bstream_quickjs_solver');
    final scripts = <String>[];
    var moduleLoads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          expect(call.method, 'executeJavaScript');
          final arguments = Map<Object?, Object?>.from(call.arguments as Map);
          scripts.add(arguments['script'] as String);
          expect(arguments['timeoutMs'], 15000);
          return 'solver-result-${scripts.length}';
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    final solver = AndroidQuickJsEjsSolver(
      channel: AndroidYtdlChannel(
        methodChannel: methodChannel,
        progressChannel: const EventChannel('test/bstream_quickjs_progress'),
      ),
      modulesLoader: () async {
        moduleLoads++;
        return 'const ejsPrelude = true;';
      },
    );
    addTearDown(solver.dispose);

    expect(
      await solver.executeJavaScript('JSON.stringify({"ok":true})'),
      'solver-result-1',
    );
    expect(
      await solver.executeJavaScript('JSON.stringify({"ok":false})'),
      'solver-result-2',
    );

    expect(moduleLoads, 1);
    expect(scripts, hasLength(2));
    expect(scripts[0], contains('const ejsPrelude = true;'));
    expect(scripts[0], contains('console.log(JSON.stringify({"ok":true}));'));
    expect(scripts[1], contains('console.log(JSON.stringify({"ok":false}));'));
  });

  test('rejects empty scripts before invoking the platform channel', () async {
    const methodChannel = MethodChannel('test/bstream_quickjs_empty');
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          invoked = true;
          return '';
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    final channel = AndroidYtdlChannel(
      methodChannel: methodChannel,
      progressChannel: const EventChannel(
        'test/bstream_quickjs_empty_progress',
      ),
    );

    await expectLater(
      channel.executeJavaScript('   '),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('quickjs_empty_script'),
        ),
      ),
    );
    expect(invoked, isFalse);
  });
}
