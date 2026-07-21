import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/domain/usecases/search_tracks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('returns empty list for blank queries', () async {
    final repository = _FakeMusicRepository();
    final usecase = SearchTracks(repository);

    final result = await usecase('   ');

    expect(result, isEmpty);
    expect(repository.lastQuery, isNull);
  });

  test('normalizes query before delegating', () async {
    final repository = _FakeMusicRepository();
    final usecase = SearchTracks(repository);

    await usecase('  daft punk  ');

    expect(repository.lastQuery, 'daft punk');
  });
}

class _FakeMusicRepository implements MusicRepository {
  String? lastQuery;

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    throw UnimplementedError();
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
  Future<List<TrackInfo>> search(String query) async {
    lastQuery = query;
    return const [];
  }
}
