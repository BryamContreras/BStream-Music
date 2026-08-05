class AppConstants {
  const AppConstants._();

  static const appName = 'BStream Music';
  static const appVersion = '1.2.2';
  static const databaseName = 'bstream_music.db';
  static const databaseVersion = 4;
  static const androidYtdlChannel = 'bstream_music/ytdl';
  static const androidYtdlProgressChannel = 'bstream_music/ytdl_progress';
  static const androidFileExportChannel = 'bstream_music/file_export';
  static const preferredNativeAudioFormat =
      'bestaudio[ext=m4a]/bestaudio[ext=aac]/bestaudio[acodec^=mp4a]/bestaudio[acodec^=aac]/bestaudio';
  static const defaultSearchLimit = 10;
}
