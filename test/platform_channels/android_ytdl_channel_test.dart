import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/platform_channels/android_ytdl_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('passes the client task id to the Android downloader', () async {
    const methodChannel = MethodChannel('test/bstream_ytdl');
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          capturedCall = call;
          return <String, Object?>{'filePath': '/music/track.m4a'};
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    final channel = AndroidYtdlChannel(
      methodChannel: methodChannel,
      progressChannel: const EventChannel('test/bstream_ytdl_progress'),
    );
    await channel.downloadAudio(
      'https://example.com/watch?v=track',
      const DownloadOptions(
        outputDirectory: '/music',
        taskId: 'client-task-123',
      ),
    );

    expect(capturedCall?.method, 'downloadAudio');
    expect(
      (capturedCall?.arguments as Map<Object?, Object?>)['taskId'],
      'client-task-123',
    );
  });

  test('maps the playback stream and its request headers', () async {
    const methodChannel = MethodChannel('test/bstream_ytdl_playback');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          expect(call.method, 'getPlaybackInfo');
          return <String, Object?>{
            'id': 'video-id',
            'title': 'Track',
            'artist': 'Artist',
            'webpage_url': 'https://www.youtube.com/watch?v=video-id',
            'streamUrl': 'https://media.example/audio.m4a',
            'stream_extension': 'm4a',
            'stream_mime_type': 'audio/mp4',
            'http_headers': <String, String>{
              'User-Agent': 'BStream test agent',
              'Referer': 'https://www.youtube.com/',
            },
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    final channel = AndroidYtdlChannel(
      methodChannel: methodChannel,
      progressChannel: const EventChannel(
        'test/bstream_ytdl_playback_progress',
      ),
    );
    final track = await channel.getPlaybackInfo(
      'https://www.youtube.com/watch?v=video-id',
    );

    expect(track.streamUrl, 'https://media.example/audio.m4a');
    expect(track.streamExtension, 'm4a');
    expect(track.streamMimeType, 'audio/mp4');
    expect(track.httpHeaders, {
      'User-Agent': 'BStream test agent',
      'Referer': 'https://www.youtube.com/',
    });
  });

  test('passes the shared result limit to Android searches', () async {
    const methodChannel = MethodChannel('test/bstream_ytdl_search');
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          capturedCall = call;
          return <Object?>[];
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    final channel = AndroidYtdlChannel(
      methodChannel: methodChannel,
      progressChannel: const EventChannel('test/bstream_ytdl_search_progress'),
    );
    final results = await channel.search('Artist - Song');

    expect(results, isEmpty);
    expect(capturedCall?.method, 'search');
    expect(capturedCall?.arguments, {
      'query': 'Artist - Song',
      'limit': AppConstants.defaultSearchLimit,
    });
    expect(AppConstants.defaultSearchLimit, 20);
  });
}
