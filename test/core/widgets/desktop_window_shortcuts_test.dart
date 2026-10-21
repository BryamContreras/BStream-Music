import 'dart:async';

import 'package:bstream_music/core/widgets/desktop_window_shortcuts.dart';
import 'package:bstream_music/platform_channels/desktop_window_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('test/desktop_window');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpShortcuts(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.windows,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      builder: (_, child) => DesktopWindowShortcuts(
        windowChannel: const DesktopWindowChannel(methodChannel: channel),
        child: child!,
      ),
      home: const Scaffold(body: TextField(autofocus: true)),
    ),
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    testWidgets(
      'F11 toggles native fullscreen on $platform with focused input',
      (tester) async {
        await pumpShortcuts(tester, platform: platform);
        await tester.pump();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pump();
        expect(calls.map((call) => call.method), [
          'toggleFullScreen',
          'toggleFullScreen',
        ]);
        expect(calls.every((call) => call.arguments == null), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('F11 does not control mobile system chrome on $platform', (
      tester,
    ) async {
      await pumpShortcuts(tester, platform: platform);
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pump();
      expect(calls, isEmpty);
    });
  }

  testWidgets('holding F11 toggles once and unrelated keys are ignored', (
    tester,
  ) async {
    await pumpShortcuts(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f11);
    expect(calls, hasLength(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(calls, hasLength(2));
  });

  testWidgets('F11 remains available on pushed routes and dialogs', (
    tester,
  ) async {
    await pumpShortcuts(tester);
    final context = tester.element(find.byType(TextField));
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Lyrics route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(calls, hasLength(1));
    unawaited(
      showDialog<void>(
        context: tester.element(find.text('Lyrics route')),
        builder: (_) => const AlertDialog(content: Text('Settings dialog')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(calls, hasLength(2));
  });

  testWidgets(
    'ignores simultaneous requests and removes its listener on dispose',
    (tester) async {
      final pending = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            await pending.future;
            return null;
          });
      await pumpShortcuts(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      expect(calls, hasLength(1));
      pending.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      expect(calls, hasLength(1));
    },
  );

  testWidgets('failed native request does not break later shortcuts', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (calls.length == 1) {
            throw PlatformException(code: 'window_unavailable');
          }
          return null;
        });
    await pumpShortcuts(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(calls, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
