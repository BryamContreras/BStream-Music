import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/domain/usecases/download_audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('delegates audio downloads to repository', () async {
    final repository = _FakeMusicRepository();
    final usecase = DownloadAudio(repository);
    const options = DownloadOptions(outputDirectory: 'downloads');

    final result = await usecase('https://example.com/track', options);

    expect(repository.lastUrl, 'https://example.com/track');
    expect(result.mediaType, DownloadMediaType.audio);
  });
}

class _FakeMusicRepository implements MusicRepository {
  String? lastUrl;

  @override
  Future<DownloadResult> downloadAudio(
    String url,
    DownloadOptions options,
  ) async {
    lastUrl = url;
    return DownloadResult(
      id: '1',
      sourceUrl: url,
      filePath: 'downloads/song.mp3',
      fileName: 'song.mp3',
      mediaType: DownloadMediaType.audio,
      completedAt: DateTime(2026),
    );
  }

  @override
  Future<TrackInfo> getInfo(String url) {
    throw UnimplementedError();
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) {
    throw UnimplementedError();
  }

  @override
  Future<List<TrackInfo>> search(String query) {
    throw UnimplementedError();
  }
}
