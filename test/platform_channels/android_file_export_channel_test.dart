import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/platform_channels/android_file_export_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('passes the requested CSV MIME type to Android', () async {
    const methodChannel = MethodChannel(AppConstants.androidFileExportChannel);
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          captured = call;
          return '/storage/emulated/0/Download/library.csv';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null),
    );

    final result =
        await const AndroidFileExportChannel(
          methodChannel: methodChannel,
        ).saveFile(
          sourcePath: '/cache/library.csv',
          fileName: 'library.csv',
          mimeType: 'text/csv',
        );

    expect(result, '/storage/emulated/0/Download/library.csv');
    expect(captured?.method, 'saveFile');
    expect(captured?.arguments, {
      'sourcePath': '/cache/library.csv',
      'fileName': 'library.csv',
      'mimeType': 'text/csv',
    });
  });
}
