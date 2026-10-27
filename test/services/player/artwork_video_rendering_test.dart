import 'dart:io';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/player/artwork_video_rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_win/video_player_win.dart';
import 'package:video_player_win/video_player_win_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform originalPlatform;
  late VideoPlayerWinPlatform originalNativePlatform;
  late _RecordingNativeVideoPlatform native;

  setUp(() {
    // The plugin's debug constructor sends clearAll once when first accessed.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('video_player_win'),
          (call) async => null,
        );
    originalPlatform = VideoPlayerPlatform.instance;
    originalNativePlatform = VideoPlayerWinPlatform.instance;
    native = _RecordingNativeVideoPlatform();
    VideoPlayerWinPlatform.instance = native;
  });
  tearDown(() {
    VideoPlayerPlatform.instance = originalPlatform;
    VideoPlayerWinPlatform.instance = originalNativePlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('video_player_win'),
          null,
        );
  });

  test('configures the unused Windows backend once', () {
    final stock = WindowsVideoPlayer();
    VideoPlayerPlatform.instance = stock;
    configureArtworkVideoRendering(platform: AppPlatformType.windows);
    final configured = VideoPlayerPlatform.instance;
    expect(configured, isA<WindowsVideoPlayer>());
    expect(identical(configured, stock), isFalse);
    configureArtworkVideoRendering(platform: AppPlatformType.windows);
    expect(VideoPlayerPlatform.instance, same(configured));
    expect(native.openCalls, 0);
  });

  test('preserves mobile and other desktop backends', () {
    for (final platform in AppPlatformType.values) {
      if (platform == AppPlatformType.windows) continue;
      final stock = WindowsVideoPlayer();
      VideoPlayerPlatform.instance = stock;
      configureArtworkVideoRendering(platform: platform);
      expect(VideoPlayerPlatform.instance, same(stock));
    }
    for (final custom in [_CustomBackend(), _CustomWindowsBackend()]) {
      VideoPlayerPlatform.instance = custom;
      configureArtworkVideoRendering(platform: AppPlatformType.windows);
      expect(VideoPlayerPlatform.instance, same(custom));
    }
  });

  test(
    'does not replace a Windows backend with an existing controller',
    () async {
      final stock = WindowsVideoPlayer();
      VideoPlayerPlatform.instance = stock;
      final id = (await stock.createWithOptions(_creationOptions()))!;
      configureArtworkVideoRendering(platform: AppPlatformType.windows);
      expect(VideoPlayerPlatform.instance, same(stock));
      expect(stock.mControllerMap[id], same(native.players[id]));
      await stock.dispose(id);
    },
  );

  testWidgets('medium view reuses the controller and inherited operations', (
    tester,
  ) async {
    VideoPlayerPlatform.instance = WindowsVideoPlayer();
    configureArtworkVideoRendering(platform: AppPlatformType.windows);
    final backend = VideoPlayerPlatform.instance as WindowsVideoPlayer;
    final id = (await backend.createWithOptions(_creationOptions()))!;
    final controller = native.players[id]!;
    final view = backend.buildViewWithOptions(VideoViewOptions(playerId: id));
    expect(view, isA<WinVideoPlayer>());
    expect((view as WinVideoPlayer).controller, same(controller));
    expect(view.filterQuality, FilterQuality.medium);
    await tester.pumpWidget(MaterialApp(home: view));
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, id);
    expect(
      tester.widget<Texture>(find.byType(Texture)).filterQuality,
      FilterQuality.medium,
    );

    await backend.setVolume(id, 0.25);
    await backend.setLooping(id, true);
    await backend.play(id);
    await backend.pause(id);
    await backend.seekTo(id, const Duration(seconds: 2));
    expect(await backend.getPosition(id), const Duration(seconds: 2));
    expect(native.openCalls, 1);
    expect(native.volume, 0.25);
    expect(native.playCalls, 1);
    expect(native.pauseCalls, 1);
    expect(controller.value.isLooping, isTrue);
    expect(backend.mControllerMap[id], same(controller));
    await tester.pumpWidget(const SizedBox.shrink());
    await backend.dispose(id);
    expect(native.disposed, [id]);
    expect(backend.mControllerMap, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

VideoCreationOptions _creationOptions() => VideoCreationOptions(
  viewType: VideoViewType.textureView,
  dataSource: DataSource(
    sourceType: DataSourceType.file,
    uri: File('fixture.mp4').absolute.uri.toString(),
  ),
);

class _CustomBackend extends VideoPlayerPlatform {}

class _CustomWindowsBackend extends WindowsVideoPlayer {}

class _RecordingNativeVideoPlatform extends VideoPlayerWinPlatform {
  final players = <int, WinVideoPlayerController>{};
  final disposed = <int>[];
  int openCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  double? volume;
  Duration position = Duration.zero;

  @override
  Future<WinVideoPlayerValue?> openVideo(
    WinVideoPlayerController player,
    int textureId,
    String path,
    Map<String, String> httpHeaders,
  ) async {
    openCalls++;
    players[42] = player;
    return const WinVideoPlayerValue(
      textureId: 42,
      duration: Duration(seconds: 20),
      size: Size(768, 768),
      isInitialized: true,
    );
  }

  @override
  WinVideoPlayerController? getPlayerByTextureId(int textureId) =>
      players[textureId];

  @override
  void unregisterPlayer(int textureId) => players.remove(textureId);

  @override
  Future<void> dispose(int textureId) async => disposed.add(textureId);

  @override
  Future<void> play(int textureId) async => playCalls++;

  @override
  Future<void> pause(int textureId) async => pauseCalls++;

  @override
  Future<void> setVolume(int textureId, double value) async => volume = value;

  @override
  Future<void> seekTo(int textureId, int milliseconds) async =>
      position = Duration(milliseconds: milliseconds);

  @override
  Future<int> getCurrentPosition(int textureId) async =>
      position.inMilliseconds;
}
