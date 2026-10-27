import 'dart:async';

import 'package:bstream_music/services/sharing/incoming_csv_file_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('bstream_music/incoming_csv');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, Object> event(String id) => {
    'id': id,
    'path': '/cache/incoming-csv/$id/Mi playlist.csv',
    'name': 'Mi playlist.csv',
    'source': 'content://documents/document/123',
    'temporary': true,
  };

  Future<void> open(Object data) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('open', data)),
      (_) => done.complete(),
    );
    await done.future;
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'drains a cold start and deduplicates an overlapping native callback',
    () async {
      final requests = <IncomingCsvFile>[];
      final start = Completer<List<Object?>>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return start.future;
        return null;
      });
      final service = NativeIncomingCsvFileService(
        platform: TargetPlatform.android,
      );
      final subscription = service.files.listen(requests.add);
      await open(event('cold'));
      start.complete([event('cold')]);
      await Future<void>.delayed(Duration.zero);
      await open(event('warm'));
      await Future<void>.delayed(Duration.zero);
      expect(requests.map((file) => file.id), ['cold', 'warm']);
      expect(requests.first.name, 'Mi playlist.csv');
      expect(requests.first.source, 'content://documents/document/123');
      await subscription.cancel();
      service.dispose();
    },
  );

  test('releases only native owned copies by id, never source paths', () async {
    final releases = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') return [];
      if (call.method == 'release') releases.add(call.arguments);
      return null;
    });
    final service = NativeIncomingCsvFileService(
      platform: TargetPlatform.android,
    );
    final file = IncomingCsvFile(
      path: '/cache/copy.csv',
      name: 'copy.csv',
      source: 'content://files/1',
      temporary: true,
      id: 'activation',
    );
    await service.release(file);
    await service.release(
      const IncomingCsvFile(
        path: '/documents/original.csv',
        name: 'original.csv',
        source: '/documents/original.csv',
      ),
    );
    expect(releases, [
      {'id': 'activation'},
    ]);
    service.dispose();
  });

  test(
    'reports native read or size failures without inventing a file',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async => []);
      final errors = <Object>[];
      final requests = <IncomingCsvFile>[];
      final service = NativeIncomingCsvFileService(
        platform: TargetPlatform.android,
      );
      final subscription = service.files.listen(
        requests.add,
        onError: errors.add,
      );
      await open({
        'id': 'invalid',
        'error': 'csv_open_failed',
        'message': 'CSV exceeds 16 MiB',
      });
      await Future<void>.delayed(Duration.zero);
      expect(requests, isEmpty);
      expect(
        errors.single,
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'csv_open_failed',
        ),
      );
      await subscription.cancel();
      service.dispose();
    },
  );

  test(
    'Linux accepts local CSV filenames and ignores links or other extensions',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async => []);
      final links = StreamController<Uri>();
      final requests = <IncomingCsvFile>[];
      final service = NativeIncomingCsvFileService(
        platform: TargetPlatform.linux,
        links: links.stream,
      );
      // Link delivery before a UI listener is buffered, just like cold native IO.
      links.add(Uri(path: '/tmp/Mi colección.CSV'));
      await Future<void>.delayed(Duration.zero);
      final subscription = service.files.listen(requests.add);
      links.add(Uri.parse('https://example.com/playlist.csv'));
      links.add(Uri.parse('file:///tmp/music.mp3'));
      links.add(Uri.parse('file:///tmp/second.csv'));
      await Future<void>.delayed(Duration.zero);
      expect(requests.map((file) => file.path), [
        '/tmp/Mi colección.CSV',
        '/tmp/second.csv',
      ]);
      expect(requests.every((file) => !file.temporary), isTrue);
      await subscription.cancel();
      service.dispose();
      await links.close();
    },
  );
}
