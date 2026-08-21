import 'package:bstream_music/platform_channels/android_ytdl_channel.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/android_web_po_token_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('caches Web tokens per video and skips Android clients', () async {
    const methodChannel = MethodChannel('test/bstream_po_tokens');
    var tokenCalls = 0;
    var disposeCalls = 0;
    final expiresAt = DateTime.now()
        .add(const Duration(hours: 1))
        .millisecondsSinceEpoch;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          if (call.method == 'getPoTokens') {
            tokenCalls++;
            return <String, Object?>{
              'available': true,
              'visitorData': 'visitor-data',
              'playerRequestPoToken': 'player-token',
              'streamingDataPoToken': 'stream-token',
              'expiresAtEpochMs': expiresAt,
            };
          }
          if (call.method == 'disposePoTokens') {
            disposeCalls++;
            return null;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    final provider = AndroidWebPoTokenProvider(
      channel: AndroidYtdlChannel(
        methodChannel: methodChannel,
        progressChannel: const EventChannel('test/bstream_po_progress'),
      ),
    );
    addTearDown(provider.dispose);

    final first = await provider.getToken(
      VideoId('abcdefghijk'),
      YoutubeApiClient.safari,
    );
    final second = await provider.getToken(
      VideoId('abcdefghijk'),
      YoutubeApiClient.safari,
    );
    final android = await provider.getToken(
      VideoId('abcdefghijk'),
      YoutubeApiClient.androidSdkless,
    );

    expect(first?.visitorData, 'visitor-data');
    expect(first?.playerRequestPoToken, 'player-token');
    expect(first?.streamingDataPoToken, 'stream-token');
    expect(second?.streamingDataPoToken, 'stream-token');
    expect(android, isNull);
    expect(tokenCalls, 1);

    provider.dispose();
    expect(disposeCalls, 1);
  });
}
