import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/downloader/yt_dlp_audio_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const track = TrackInfo(
    id: 'video-id',
    title: 'Track',
    artist: 'Artist',
    url: 'https://www.youtube.com/watch?v=video-id',
  );

  test('uses managed playback when the downloader supports it', () async {
    final downloader = _ManagedFakeDownloader(
      ManagedPlaybackResource(
        filePath: p.join(Directory.systemTemp.path, 'video-id.140.m4a'),
        extension: 'm4a',
        mimeType: 'audio/mp4',
        formatId: '140',
        codec: 'mp4a.40.2',
      ),
    );

    final result = await YtDlpAudioResolver(downloader).resolve(track);

    expect(downloader.managedCalls, 1);
    expect(downloader.playbackInfoCalls, 0);
    expect(result.source, AudioStreamSource.ytDlp);
    expect(Uri.parse(result.streamUrl).scheme, 'file');
    expect(result.streamExtension, 'm4a');
    expect(result.streamMimeType, 'audio/mp4');
    expect(result.formatId, '140');
    expect(result.codec, 'mp4a.40.2');
    expect(result.isUsable, isTrue);
  });

  test('keeps direct URL compatibility for simple downloaders', () async {
    final downloader = _DirectFakeDownloader();

    final result = await YtDlpAudioResolver(downloader).resolve(track);

    expect(downloader.playbackInfoCalls, 1);
    expect(result.streamUrl, 'https://media.example/audio.m4a');
    expect(result.source, AudioStreamSource.ytDlp);
  });
}

class _DirectFakeDownloader implements DownloaderService {
  int playbackInfoCalls = 0;

  @override
  Stream<DownloadProgress> get progressStream => const Stream.empty();

  @override
  Future<TrackInfo> getPlaybackInfo(String url) async {
    playbackInfoCalls++;
    return TrackInfo(
      id: 'video-id',
      title: 'Track',
      artist: 'Artist',
      url: url,
      streamUrl: 'https://media.example/audio.m4a',
      streamExtension: 'm4a',
    );
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<TrackInfo> getInfo(String url) => throw UnimplementedError();

  @override
  Future<List<TrackInfo>> search(String query) => throw UnimplementedError();

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) =>
      throw UnimplementedError();
}

class _ManagedFakeDownloader extends _DirectFakeDownloader
    implements ManagedPlaybackDownloader {
  _ManagedFakeDownloader(this.resource);

  final ManagedPlaybackResource resource;
  int managedCalls = 0;

  @override
  Future<ManagedPlaybackResource> prepareManagedPlayback(String url) async {
    managedCalls++;
    return resource;
  }
}
