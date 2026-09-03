import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/platform_channels/ios_file_export_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('exports an existing iOS file by source path', () async {
    const methodChannel = MethodChannel(AppConstants.fileExportChannel);
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          received = call;
          return '/private/exported/library.zip';
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    const channel = IosFileExportChannel(methodChannel: methodChannel);
    final destination = await channel.saveFile(
      sourcePath: '/private/tmp/library.zip',
      fileName: 'bstream-backup.zip',
    );

    expect(destination, '/private/exported/library.zip');
    expect(received?.method, 'saveFile');
    expect(received?.arguments, <String, Object>{
      'sourcePath': '/private/tmp/library.zip',
      'fileName': 'bstream-backup.zip',
      'mimeType': 'application/zip',
    });
  });
}
