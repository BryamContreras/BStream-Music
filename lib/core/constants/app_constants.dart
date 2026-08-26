class AppConstants {
  const AppConstants._();

  static const appName = 'BStream Music';
  static const appVersion = '1.2.5';
  static const databaseName = 'bstream_music.db';
  static const databaseVersion = 8;
  static const androidYtdlChannel = 'bstream_music/ytdl';
  static const androidYtdlProgressChannel = 'bstream_music/ytdl_progress';
  static const androidFileExportChannel = 'bstream_music/file_export';
  static const androidScreenChannel = 'bstream_music/screen';
  static const androidExternalAudioChannel = 'bstream_music/external_audio';
  static const androidAppActivationChannel = 'bstream_music/app_activation';
  static const preferredNativeAudioFormat =
      'bestaudio[ext=m4a]/bestaudio[ext=aac]/bestaudio[acodec^=mp4a]/bestaudio[acodec^=aac]/bestaudio';
  static const defaultSearchLimit = 20;
  static const supportDevelopmentUrl = 'https://ko-fi.com/soybryam06c/donate';
  static const githubRepositoryUrl =
      'https://github.com/BryamContreras/BStream-Music';
}
