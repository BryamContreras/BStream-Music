import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/errors/app_exception.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/platform/app_platform.dart';
import '../../../../core/utils/safe_file_name.dart';
import '../../../../platform_channels/android_ytdl_channel.dart';
import '../../../../services/downloader/android_downloader_service.dart';
import '../../../../services/downloader/desktop_downloader_service.dart';
import '../../../../services/downloader/downloader_service.dart';
import '../../../../services/live/tiktok_live_command_service.dart';
import '../../../../services/player/just_audio_player_service.dart';
import '../../../../services/player/media_kit_player_service.dart';
import '../../../../services/player/player_service.dart';
import '../../../../services/storage/backup_service.dart';
import '../../../../services/storage/local_database_service.dart';
import '../../data/datasources/local_music_datasource.dart';
import '../../data/datasources/remote_music_datasource.dart';
import '../../data/models/track_info_model.dart';
import '../../data/repositories/library_repository_impl.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/entities/download_options.dart';
import '../../domain/entities/download_result.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/repositories/music_repository.dart';
import '../../domain/usecases/download_audio.dart';
import '../../domain/usecases/get_playback_info.dart';
import '../../domain/usecases/get_history.dart';
import '../../domain/usecases/get_library_tracks.dart';
import '../../domain/usecases/get_playlists.dart';
import '../../domain/usecases/get_track_info.dart';
import '../../domain/usecases/search_tracks.dart';

part 'app_strings.dart';
part 'download_controller.dart';
part 'local_track_download_helper.dart';
part 'player_controller.dart';
part 'playlists_controller.dart';
part 'remote_playback_cache.dart';
part 'remote_track_resolver.dart';
part 'search_controller.dart';
part 'settings_controller.dart';
part 'sleep_timer_controller.dart';
part 'tiktok_live_controller.dart';

final downloaderServiceProvider = Provider<DownloaderService>((ref) {
  if (AppPlatform.isAndroid) {
    return AndroidDownloaderService(AndroidYtdlChannel());
  }

  if (AppPlatform.isDesktop) {
    final service = DesktopDownloaderService();
    ref.onDispose(service.dispose);
    return service;
  }

  throw const UnsupportedPlatformException(
    'BStream Music soporta Android, Windows y macOS.',
  );
});

final downloaderWarmupProvider = FutureProvider<void>((ref) async {
  await ref.watch(downloaderServiceProvider).initialize();
});

final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = AppPlatform.isDesktop
      ? MediaKitPlayerService()
      : JustAudioPlayerService();
  ref.onDispose(service.dispose);
  return service;
});

final databaseServiceProvider = Provider<LocalDatabaseService>((ref) {
  return LocalDatabaseService();
});

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(ref.watch(databaseServiceProvider));
});

final remoteMusicDataSourceProvider = Provider<RemoteMusicDataSource>((ref) {
  return RemoteMusicDataSource(ref.watch(downloaderServiceProvider));
});

final localMusicDataSourceProvider = Provider<LocalMusicDataSource>((ref) {
  return LocalMusicDataSource(ref.watch(databaseServiceProvider));
});

final musicRepositoryProvider = Provider<MusicRepository>((ref) {
  return MusicRepositoryImpl(ref.watch(remoteMusicDataSourceProvider));
});

final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  return LibraryRepositoryImpl(ref.watch(localMusicDataSourceProvider));
});

final getTrackInfoProvider = Provider<GetTrackInfo>((ref) {
  return GetTrackInfo(ref.watch(musicRepositoryProvider));
});

final getPlaybackInfoProvider = Provider<GetPlaybackInfo>((ref) {
  return GetPlaybackInfo(ref.watch(musicRepositoryProvider));
});

final searchTracksProvider = Provider<SearchTracks>((ref) {
  return SearchTracks(ref.watch(musicRepositoryProvider));
});

final downloadAudioProvider = Provider<DownloadAudio>((ref) {
  return DownloadAudio(ref.watch(musicRepositoryProvider));
});

final getLibraryTracksProvider = Provider<GetLibraryTracks>((ref) {
  return GetLibraryTracks(ref.watch(libraryRepositoryProvider));
});

final getPlaylistsProvider = Provider<GetPlaylists>((ref) {
  return GetPlaylists(ref.watch(libraryRepositoryProvider));
});

final getHistoryProvider = Provider<GetHistory>((ref) {
  return GetHistory(ref.watch(libraryRepositoryProvider));
});

final libraryTracksProvider = FutureProvider<List<LocalTrack>>((ref) {
  return ref.watch(getLibraryTracksProvider).call();
});

final historyProvider = FutureProvider<List<LocalTrack>>((ref) {
  return ref.watch(getHistoryProvider).call();
});

final tiktokLiveCommandServiceProvider = Provider<TikTokLiveCommandService>((
  ref,
) {
  final service = TikTokLiveCommandService();
  ref.onDispose(service.dispose);
  return service;
});
