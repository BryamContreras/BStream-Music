import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/theme/app_theme.dart';
import 'lyrics_animation_style.dart';

enum AppLanguage { spanish, english }

extension AppLanguageLabel on AppLanguage {
  String get label => switch (this) {
    AppLanguage.spanish => 'Espanol',
    AppLanguage.english => 'English',
  };

  String get code => switch (this) {
    AppLanguage.spanish => 'es',
    AppLanguage.english => 'en',
  };

  static AppLanguage fromCode(String? code) {
    return switch (code) {
      'en' => AppLanguage.english,
      _ => AppLanguage.spanish,
    };
  }
}

class AppStrings {
  const AppStrings(this.appLanguage);

  final AppLanguage appLanguage;

  bool get isEnglish => appLanguage == AppLanguage.english;

  String choose(String es, String en) => isEnglish ? en : es;

  String get home => choose('Inicio', 'Home');
  String get refreshHomeRecommendations =>
      choose('Refrescar recomendaciones', 'Refresh recommendations');
  String get refreshingHomeRecommendations =>
      choose('Refrescando recomendaciones', 'Refreshing recommendations');
  String get recentlyPlayed =>
      choose('Escuchado recientemente', 'Recently played');
  String get myPlaylists => choose('Mis playlists', 'My playlists');
  String get mix => 'Mix';
  String get homeCollectionLoadError => choose(
    'No se pudo cargar esta seleccion.',
    'This selection could not be loaded.',
  );
  String get homeCollectionEmpty => choose(
    'Esta seleccion no tiene canciones disponibles.',
    'This selection has no available songs.',
  );
  String get noRecentSongs => choose(
    'Aun no has escuchado canciones.',
    'No recently played songs yet.',
  );
  String get search => choose('Buscar', 'Search');
  String get clearSearch => choose('Limpiar búsqueda', 'Clear search');
  String get searchTitle => choose('Búsqueda', 'Search');
  String get player => choose('Reproductor', 'Player');
  String get library => choose('Biblioteca', 'Library');
  String get settings => choose('Ajustes', 'Settings');
  String get searchHint =>
      choose('Canción, artista o álbum', 'Song, artist, or album');
  String get searchEmptyTitle => choose(
    'Busca canciones, artistas o enlaces',
    'Search songs, artists, or links',
  );
  String get searchEmptySubtitle =>
      choose('Los resultados apareceran aqui.', 'Results will appear here.');
  String get searchErrorTitle => choose('No se pudo buscar', 'Search failed');
  String get searchSongs => choose('Canciones', 'Songs');
  String get searchVideos => choose('Videos', 'Videos');
  String get searchAlbums => choose('Álbumes', 'Albums');
  String get searchSongsEmpty => choose(
    'No encontramos canciones para esta búsqueda.',
    'No songs matched this search.',
  );
  String get searchVideosEmpty => choose(
    'No encontramos videos para esta búsqueda.',
    'No videos matched this search.',
  );
  String get searchAlbumsEmpty => choose(
    'No encontramos álbumes para esta búsqueda.',
    'No albums matched this search.',
  );
  String get searchInnerTubeFallback => choose(
    'InnerTube no respondió. Se usó yt-dlp y sólo se muestran videos.',
    'InnerTube did not respond. yt-dlp was used, so only videos are shown.',
  );
  String get searchYtDlpVideoOnly => choose(
    'Esta búsqueda usa yt-dlp y sólo puede mostrar videos.',
    'This search uses yt-dlp and can only show videos.',
  );
  String openAlbum(String title) =>
      choose('Abrir álbum $title', 'Open album $title');
  String openCollection(String title) => choose('Abrir $title', 'Open $title');
  String get albumLoadError => choose(
    'No se pudieron cargar las canciones del álbum.',
    'The album songs could not be loaded.',
  );
  String get albumWithoutSongs => choose(
    'Este álbum no tiene canciones disponibles.',
    'This album has no available songs.',
  );
  String collectionSongCount(int count) => choose(
    count == 1 ? '1 canción' : '$count canciones',
    count == 1 ? '1 song' : '$count songs',
  );
  String get play => choose('Reproducir', 'Play');
  String get pause => choose('Pausar', 'Pause');
  String get previous => choose('Anterior', 'Previous');
  String get next => choose('Siguiente', 'Next');
  String get download => choose('Descargar', 'Download');
  String get downloadAudio => choose('Descargar audio', 'Download audio');
  String get noPlayback => choose('Sin reproduccion', 'Nothing playing');
  String get nowPlaying => choose('En reproduccion', 'Now playing');
  String get noTitle => choose('Sin titulo', 'Untitled');
  String get unknownArtist => choose('Desconocido', 'Unknown');
  String get playbackError => choose('Error de reproduccion', 'Playback error');
  String get externalAudioFolderUnavailable => choose(
    'Se reproducira el audio elegido, pero Android no permitio cargar el resto de la carpeta.',
    'The selected audio will play, but Android did not allow the rest of the folder to be loaded.',
  );
  String get volume => choose('Volumen', 'Volume');
  String get volumeControl => choose('Control de Volumen', 'Volume control');
  String get lyrics => choose('Letras', 'Lyrics');
  String get lyricsLoading =>
      choose('Buscando la letra...', 'Finding lyrics...');
  String get lyricsNotFound => choose(
    'No encontramos una letra para esta cancion.',
    'We could not find lyrics for this song.',
  );
  String get lyricsLoadError =>
      choose('No se pudo obtener la letra.', 'Lyrics could not be loaded.');
  String get similarLyrics => choose('Letras similares', 'Similar lyrics');
  String get similarLyricsLoading =>
      choose('Buscando letras similares...', 'Finding similar lyrics...');
  String get similarLyricsEmpty => choose(
    'No encontramos letras similares seguras.',
    'We could not find any safe similar lyrics.',
  );
  String get chooseSimilarLyrics =>
      choose('Elige la coincidencia correcta', 'Choose the correct match');
  String get manualLyricsSearchHint =>
      choose('Buscar por otro titulo', 'Search by another title');
  String get manualLyricsSearchAction =>
      choose('Buscar letras', 'Search lyrics');
  String get syncedLyricsLabel => choose('Sincronizada', 'Synchronized');
  String get plainLyricsLabel => choose('Sin sincronizar', 'Not synchronized');
  String get backToLyrics => choose('Volver', 'Back');
  String get lyricsNoInternet =>
      choose('No hay conexión a Internet.', 'No Internet connection.');
  String get lyricsInstrumental => choose(
    'Esta cancion aparece como instrumental.',
    'This track is marked as instrumental.',
  );
  String get lyricsUnsynced => choose(
    'Esta letra no incluye tiempos sincronizados.',
    'These lyrics do not include synchronized timing.',
  );
  String get lyricsOffset => choose('Desfase', 'Offset');
  String get lyricsOffsetHint => choose(
    'Ajustalo si la letra aparece antes o despues de la voz.',
    'Adjust it if the lyrics appear before or after the vocals.',
  );
  String get resetLyricsOffset => choose('Restablecer desfase', 'Reset offset');
  String get lyricsAlignment =>
      choose('Alineación de letras', 'Lyrics alignment');
  String get centerLyrics => choose('Centrar letras', 'Center lyrics');
  String get useNormalLyricsAlignment =>
      choose('Usar alineación normal', 'Use normal alignment');
  String get normalLyricsAlignment => choose('Normal', 'Normal');
  String get centeredLyricsAlignment => choose('Centrada', 'Centered');
  String get lyricsAppearance =>
      choose('Animación y alineación', 'Animation and alignment');
  String get lyricsAppearanceSummary => choose(
    'Personaliza cómo aparecen y se alinean las letras.',
    'Customize how lyrics appear and align.',
  );
  String get lyricsAnimation => choose('Animación', 'Animation');
  String get lyricsAnimationSmooth => choose('Suave', 'Smooth');
  String get lyricsAnimationSlide => choose('Deslizar', 'Slide');
  String get lyricsAnimationHighlight => choose('Resaltar', 'Highlight');
  String get lyricsAnimationNone => choose('Sin animación', 'No animation');
  String get lyricsPreview => choose('Vista previa', 'Preview');
  String get lyricsPreviewPreviousLine =>
      choose('La noche empieza a brillar', 'The night begins to glow');
  String get lyricsPreviewActiveLine =>
      choose('Cantamos juntos esta canción', 'We sing this song together');
  String get lyricsPreviewNextLine =>
      choose('Y el ritmo vuelve a empezar', 'And the rhythm starts again');
  String get replayAnimation =>
      choose('Reproducir animación', 'Play animation');
  String lyricsAnimationLabel(LyricsAnimationStyle style) => switch (style) {
    LyricsAnimationStyle.smooth => lyricsAnimationSmooth,
    LyricsAnimationStyle.slide => lyricsAnimationSlide,
    LyricsAnimationStyle.highlight => lyricsAnimationHighlight,
    LyricsAnimationStyle.none => lyricsAnimationNone,
  };
  String get retry => choose('Reintentar', 'Retry');
  String get lyricsSource =>
      choose('Letras proporcionadas por LRCLIB', 'Lyrics provided by LRCLIB');
  String get tapLyricsToSeek => choose(
    'Toca una linea para ir a ese momento.',
    'Tap a line to seek to that moment.',
  );
  String get close => choose('Cerrar', 'Close');
  String get moreOptions => choose('Mas opciones', 'More options');
  String get addToPlaylist => choose('Anadir a playlist', 'Add to playlist');
  String get favorites => choose('Favoritos', 'Favorites');
  String get addToFavorites => choose('Anadir a favoritos', 'Add to favorites');
  String get removeFromFavorites =>
      choose('Quitar de favoritos', 'Remove from favorites');
  String get addedToFavorites =>
      choose('Cancion agregada a favoritos.', 'Song added to favorites.');
  String get removedFromFavorites =>
      choose('Cancion quitada de favoritos.', 'Song removed from favorites.');
  String get choosePlaylist => choose('Elegir playlist', 'Choose playlist');
  String selectedSongs(int count) => choose(
    count == 1 ? '1 cancion seleccionada' : '$count canciones seleccionadas',
    count == 1 ? '1 song selected' : '$count songs selected',
  );
  String songsAddedToPlaylist(int count) => choose(
    count == 1
        ? 'Cancion agregada a la playlist.'
        : '$count canciones agregadas a la playlist.',
    count == 1 ? 'Song added to playlist.' : '$count songs added to playlist.',
  );
  String get songsAlreadyInPlaylist => choose(
    'Las canciones seleccionadas ya estan en esa playlist.',
    'The selected songs are already in that playlist.',
  );
  String get createPlaylistFirst =>
      choose('Crea una playlist primero.', 'Create a playlist first.');
  String get songAddedToPlaylist =>
      choose('Cancion agregada a la playlist.', 'Song added to playlist.');
  String get downloadQueued =>
      choose('Descarga agregada a la cola.', 'Download added to queue.');
  String get back => choose('Volver', 'Back');
  String get error => choose('Error', 'Error');
  String get downloads => choose('Descargas', 'Downloads');
  String get downloadedSongs =>
      choose('Canciones descargadas', 'Downloaded songs');
  String get liveQueue => choose('LIVE', 'LIVE');
  String get liveQueueTitle => choose('Cola LIVE', 'LIVE queue');
  String get playbackQueue => choose('Cola de reproduccion', 'Playback queue');
  String get playbackQueueEmpty => choose(
    'No hay canciones en la cola actual.',
    'There are no songs in the current queue.',
  );
  String get liveQueueEmpty => choose(
    'Los pedidos !play apareceran aqui.',
    'Live !play requests will appear here.',
  );
  String get clearLiveQueue => choose('Limpiar cola LIVE', 'Clear LIVE queue');
  String get requestedBy => choose('Pedido por', 'Requested by');
  String get moderator => choose('Moderador', 'Moderator');
  String get commandPermissions =>
      choose('Quien puede usar los comandos', 'Who can use commands');
  String get everyone => choose('Todos', 'Everyone');
  String get moderators => choose('Moderadores', 'Moderators');
  String get reusedDownload => choose('Ya descargada', 'Already downloaded');
  String get playlist => choose('Playlist', 'Playlist');
  String get newPlaylist => choose('Nueva playlist', 'New playlist');
  String get createPlaylist => choose('Crear playlist', 'Create playlist');
  String get create => choose('Crear', 'Create');
  String get cancel => choose('Cancelar', 'Cancel');
  String get name => choose('Nombre', 'Name');
  String get filterSongs => choose('Filtrar canciones', 'Filter songs');
  String get noSongsToShow =>
      choose('No hay canciones para mostrar.', 'No songs to show.');
  String get noLocalPlaylists => choose(
    'Todavia no hay playlists locales.',
    'There are no local playlists yet.',
  );
  String get playlistMissing =>
      choose('La playlist ya no existe.', 'This playlist no longer exists.');
  String get deleteSong => choose('Eliminar cancion', 'Delete song');
  String get deleteSelectedSongs =>
      choose('Eliminar canciones', 'Delete songs');
  String confirmDeleteSongs(int count) => choose(
    count == 1
        ? 'Se eliminara la cancion descargada y su archivo.'
        : 'Se eliminaran $count canciones descargadas y sus archivos.',
    count == 1
        ? 'The downloaded song and its file will be deleted.'
        : '$count downloaded songs and their files will be deleted.',
  );
  String songsDeleted(int count) => choose(
    count == 1 ? 'Cancion eliminada.' : '$count canciones eliminadas.',
    count == 1 ? 'Song deleted.' : '$count songs deleted.',
  );
  String get delete => choose('Eliminar', 'Delete');
  String get rename => choose('Renombrar', 'Rename');
  String get renameSong => choose('Renombrar cancion', 'Rename song');
  String get renamePlaylist => choose('Renombrar playlist', 'Rename playlist');
  String get deletePlaylist => choose('Eliminar playlist', 'Delete playlist');
  String get songRenamed => choose('Cancion renombrada.', 'Song renamed.');
  String get playlistRenamed =>
      choose('Playlist renombrada.', 'Playlist renamed.');
  String get playlistDeleted =>
      choose('Playlist eliminada.', 'Playlist deleted.');
  String get confirmDeletePlaylist => choose(
    'Esta accion no elimina las canciones guardadas.',
    'This does not delete downloaded songs.',
  );
  String get songDeleted => choose('Cancion eliminada.', 'Song deleted.');
  String get removeFromPlaylist =>
      choose('Quitar de playlist', 'Remove from playlist');
  String removeSelectedSongs(int count, {required bool favorites}) => choose(
    favorites
        ? (count == 1
              ? 'Quitar la cancion de Favoritos?'
              : 'Quitar $count canciones de Favoritos?')
        : (count == 1
              ? 'Quitar la cancion de esta playlist?'
              : 'Quitar $count canciones de esta playlist?'),
    favorites
        ? (count == 1
              ? 'Remove the song from Favorites?'
              : 'Remove $count songs from Favorites?')
        : (count == 1
              ? 'Remove the song from this playlist?'
              : 'Remove $count songs from this playlist?'),
  );
  String songsRemovedFromPlaylist(int count, {required bool favorites}) =>
      choose(
        favorites
            ? (count == 1
                  ? 'Cancion quitada de Favoritos.'
                  : '$count canciones quitadas de Favoritos.')
            : (count == 1
                  ? 'Cancion quitada de la playlist.'
                  : '$count canciones quitadas de la playlist.'),
        favorites
            ? (count == 1
                  ? 'Song removed from Favorites.'
                  : '$count songs removed from Favorites.')
            : (count == 1
                  ? 'Song removed from playlist.'
                  : '$count songs removed from playlist.'),
      );
  String get folder => choose('Carpeta', 'Folder');
  String get exportBackup => choose('Exportar', 'Export');
  String get importBackup => choose('Importar', 'Import');
  String get importData => choose('Importar', 'Import');
  String get exportData => choose('Exportar', 'Export');
  String get importFromLocalBackup =>
      choose('Importar desde respaldo local', 'Import from local backup');
  String get importBackupSummary => choose(
    'Restaura y reemplaza la biblioteca con un ZIP que incluye el audio.',
    'Restore and replace the library from a ZIP that includes the audio.',
  );
  String get importFromCsv =>
      choose('Importar desde archivo .csv', 'Import from a .csv file');
  String get importCsvSummary => choose(
    'Combina listas y metadatos; tras confirmar, descargará las canciones.',
    'Merge lists and metadata; after confirmation, songs will be downloaded.',
  );
  String get exportLocalBackup =>
      choose('Exportar respaldo local', 'Export local backup');
  String get exportBackupSummary => choose(
    'Crea un ZIP con la biblioteca, sus datos y los archivos de audio.',
    'Create a ZIP with the library, its data, and the audio files.',
  );
  String get exportToCsv =>
      choose('Exportar archivo .csv', 'Export a .csv file');
  String get exportCsvSummary => choose(
    'Compatible con MetroList, Harmony y formatos comunes; no incluye audio.',
    'Compatible with MetroList, Harmony, and common formats; no audio included.',
  );
  String get csvImportTitle =>
      choose('Importar y descargar canciones', 'Import and download songs');
  String csvImportPreview({
    required int tracks,
    required int playlists,
    required int invalid,
    required int duplicates,
  }) => choose(
    'Se encontraron $tracks canciones y $playlists playlists. '
        'Se omitiran $invalid filas invalidas y se combinaran $duplicates '
        'filas repetidas. '
        'Las canciones existentes se reutilizaran; las faltantes se '
        'descargaran una por una.',
    '$tracks songs and $playlists playlists were found. $invalid invalid '
        'rows will be skipped and $duplicates repeated rows will be merged. '
        'Existing songs '
        'will be reused; missing songs will be downloaded one at a time.',
  );
  String get csvImportDataNotice => choose(
    'La descarga puede consumir datos y almacenamiento. Puedes detener la '
        'importacion despues de la cancion activa.',
    'Downloads may use data and storage. You can stop the import after the '
        'current song.',
  );
  String get importAndDownload =>
      choose('Importar y descargar', 'Import and download');
  String get csvImporting =>
      choose('Importando biblioteca', 'Importing library');
  String csvImportProgress(int processed, int total) =>
      choose('$processed de $total canciones', '$processed of $total songs');
  String get stopAfterCurrent =>
      choose('Detener despues de esta cancion', 'Stop after this song');
  String get csvStopRequested => choose(
    'Se detendra al terminar la cancion activa.',
    'The import will stop after the current song.',
  );
  String get csvImportCompleted =>
      choose('Importacion terminada', 'Import complete');
  String csvImportResult({
    required int downloaded,
    required int reused,
    required int failed,
    required int playlists,
  }) => choose(
    '$downloaded descargadas, $reused reutilizadas, $failed con error y '
        '$playlists playlists actualizadas.',
    '$downloaded downloaded, $reused reused, $failed failed, and $playlists '
        'playlists updated.',
  );
  String get csvImportCancelled => choose(
    'La importacion se detuvo. Los elementos completados se conservaron.',
    'The import stopped. Completed items were kept.',
  );
  String get csvNoSongs => choose(
    'El CSV no contiene canciones compatibles.',
    'The CSV contains no compatible songs.',
  );
  String get csvImportFailed => choose(
    'No se pudo importar el archivo CSV.',
    'The CSV file could not be imported.',
  );
  String get chooseCsvProfile =>
      choose('Formato del archivo CSV', 'CSV file format');
  String get csvProfileBStream => choose('BStream completo', 'Full BStream');
  String get csvProfileBStreamSummary => choose(
    'Conserva playlists, posiciones, IDs y metadatos.',
    'Preserves playlists, positions, IDs, and metadata.',
  );
  String get csvProfileMetroList => 'MetroList';
  String get csvProfileMetroListSummary => choose(
    'Titulo, artista, album e ID de YouTube.',
    'Title, artist, album, and YouTube ID.',
  );
  String get csvProfileHarmony => 'Harmony / RiMusic';
  String get csvProfileHarmonySummary => choose(
    'Formato de playlists y metadatos compatible con Harmony y RiMusic.',
    'Playlist and metadata format compatible with Harmony and RiMusic.',
  );
  String get csvProfileSoundiiz => 'Soundiiz';
  String get csvProfileSoundiizSummary => choose(
    'Formato sencillo de titulo, artista, album e ISRC.',
    'Simple title, artist, album, and ISRC format.',
  );
  String get csvExported =>
      choose('Archivo CSV exportado.', 'CSV file exported.');
  String get csvExportFailed => choose(
    'No se pudo exportar el archivo CSV.',
    'The CSV file could not be exported.',
  );
  String get exportBackupTitle => choose('Exportar respaldo', 'Export backup');
  String get importBackupTitle => choose('Importar respaldo', 'Import backup');
  String get backupExported =>
      choose('Respaldo exportado.', 'Backup exported.');
  String get backupImported =>
      choose('Respaldo importado.', 'Backup imported.');
  String get backupCancelled =>
      choose('Operacion cancelada.', 'Operation cancelled.');
  String get backupFailed =>
      choose('No se pudo completar el respaldo.', 'Backup failed.');
  String get replaceLibraryTitle =>
      choose('Reemplazar biblioteca', 'Replace library');
  String get replaceLibraryMessage => choose(
    'Este respaldo reemplazará la biblioteca, las playlists y los archivos '
        'de audio actuales. Esta acción no se puede deshacer.',
    'This backup will replace the current library, playlists, and audio '
        'files. This action cannot be undone.',
  );
  String get restoreAndReplace =>
      choose('Restaurar y reemplazar', 'Restore and replace');
  String get language => choose('Idioma', 'Language');
  String get general => choose('General', 'General');
  String get appearance => choose('Apariencia', 'Appearance');
  String get theme => choose('Tema', 'Theme');
  String get themeAndAccentColor =>
      choose('Tema y color del acento', 'Theme and accent color');
  String get themeSystem => choose('Sistema', 'System');
  String get themeLight => choose('Claro', 'Light');
  String get themeDark => choose('Oscuro', 'Dark');
  String get accentColor => choose('Color de acento', 'Accent color');
  String accentLabel(AppAccent accent) => switch (accent) {
    AppAccent.white => choose('Blanco', 'White'),
    AppAccent.green => choose('Verde', 'Green'),
    AppAccent.blue => choose('Azul', 'Blue'),
    AppAccent.purple => choose('Morado', 'Purple'),
    AppAccent.orange => choose('Naranja', 'Orange'),
    AppAccent.red => choose('Rojo', 'Red'),
    AppAccent.yellow => choose('Amarillo', 'Yellow'),
    AppAccent.pink => choose('Rosa', 'Pink'),
    AppAccent.teal => choose('Turquesa', 'Teal'),
    AppAccent.cyan => choose('Cian', 'Cyan'),
    AppAccent.indigo => choose('Índigo', 'Indigo'),
    AppAccent.lime => choose('Lima', 'Lime'),
    AppAccent.mint => choose('Menta', 'Mint'),
    AppAccent.magenta => choose('Magenta', 'Magenta'),
    AppAccent.coral => choose('Coral', 'Coral'),
    AppAccent.brown => choose('Marrón', 'Brown'),
    AppAccent.lavender => choose('Lavanda', 'Lavender'),
    AppAccent.ocean => choose('Océano', 'Ocean'),
  };
  String get spanish => choose('Espanol', 'Spanish');
  String get english => 'English';
  String get playback => choose('Reproducción', 'Playback');
  String get sleepTimer => choose('Temporizador', 'Sleep timer');
  String get storage => choose('Almacenamiento', 'Storage');
  String get downloadsAndBackup =>
      choose('Descargas y respaldo', 'Downloads and backup');
  String get storageSummary => choose(
    'Administra las descargas y el respaldo de tu biblioteca.',
    'Manage downloads and your library backup.',
  );
  String get integrations => choose('Integraciones', 'Integrations');
  String get automaticShutdown =>
      choose('Apagado automatico', 'Automatic shutdown');
  String get sleepTimerOff => choose('Desactivado', 'Off');
  String get customDuration => choose('Personalizar', 'Custom');
  String get timerDuration =>
      choose('Duracion del temporizador', 'Timer duration');
  String get startTimer => choose('Iniciar', 'Start');
  String get invalidTimerDuration => choose(
    'Ingresa una duracion entre 1 y 720 minutos.',
    'Enter a duration between 1 and 720 minutes.',
  );
  String get desktopTools => choose('Herramientas desktop', 'Desktop tools');
  String get liveConnection => choose('Conexion LIVE', 'LIVE connection');
  String get liveConnectionSummary => choose(
    'Conecta un LIVE y configura quien puede pedir canciones.',
    'Connect a LIVE and choose who can request songs.',
  );
  String get liveUnavailable => choose(
    'Conexion LIVE no disponible en este dispositivo.',
    'LIVE connection is not available on this device.',
  );
  String get backupSummary => choose(
    'Exporta o restaura tu biblioteca y configuracion.',
    'Export or restore your library and settings.',
  );
  String get tiktokLive => choose('TikTok LIVE', 'TikTok LIVE');
  String get tiktokLiveUser =>
      choose('@usuario o link del live', '@user or live link');
  String get saveLiveRequestsToLibrary => choose(
    'Guardar pedidos LIVE en Biblioteca',
    'Save LIVE requests to Library',
  );
  String get saveLiveRequestsToLibraryEnabled => choose(
    'Descarga y guarda cada pedido en Biblioteca antes de reproducirlo.',
    'Download and save each request to Library before playing it.',
  );
  String get saveLiveRequestsToLibraryDisabled => choose(
    'Reproduce de forma remota con caché temporal, sin agregarlo a Biblioteca.',
    'Play remotely with temporary cache, without adding it to Library.',
  );
  String get saveLiveRequestsToLibraryLocked => choose(
    'Limpia la cola LIVE para cambiar esta opción.',
    'Clear the LIVE queue to change this option.',
  );
  String get readyForRemotePlayback =>
      choose('Lista para reproduccion remota', 'Ready for remote playback');
  String get connect => choose('Conectar', 'Connect');
  String get disconnect => choose('Desconectar', 'Disconnect');
  String get connected => choose('conectado', 'connected');
  String get disconnected => choose('desconectado', 'disconnected');
  String get lastCommand => choose('Ultimo comando', 'Last command');
  String get pendingRequests =>
      choose('Pedidos pendientes', 'Pending requests');
  String get roomId => 'room_id';
  String get browseFolder => choose('Explorar carpeta', 'Browse folder');
  String get downloadFolderSaveFailed => choose(
    'No se pudo guardar la carpeta de descargas.',
    'The downloads folder could not be saved.',
  );
  String get verify => choose('Verificar', 'Check');
  String get available => choose('disponible', 'available');
  String get notFound => choose('no encontrado', 'not found');

  String themeModeLabel(AppThemeMode mode) => switch (mode) {
    AppThemeMode.system => themeSystem,
    AppThemeMode.light => themeLight,
    AppThemeMode.dark => themeDark,
  };
  String get selectDownloadFolder =>
      choose('Selecciona carpeta de descargas', 'Select downloads folder');
  String get queued => choose('En cola', 'Queued');
  String get downloading => choose('Descargando', 'Downloading');
  String get completed => choose('Completado', 'Completed');
  String get activateShuffle => choose('Activar aleatorio', 'Enable shuffle');
  String get deactivateShuffle =>
      choose('Desactivar aleatorio', 'Disable shuffle');
  String get repeatQueue => choose('Repetir cola', 'Repeat queue');
  String get repeatOne => choose('Repetir una', 'Repeat one');
  String get disableRepeat => choose('Desactivar repetir', 'Disable repeat');

  String sleepTimerRemaining(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 24 * 60 * 60);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final formatted = hours > 0
        ? '${hours.toString().padLeft(2, '0')}:'
              '${minutes.toString().padLeft(2, '0')}:'
              '${seconds.toString().padLeft(2, '0')}'
        : '${minutes.toString().padLeft(2, '0')}:'
              '${seconds.toString().padLeft(2, '0')}';
    return choose(
      'El reproductor se detendra en $formatted',
      'The player will stop in $formatted',
    );
  }

  String timerMinutes(int minutes) => choose('$minutes min', '$minutes min');

  String appVersion(String version) =>
      choose('Versión $version', 'Version $version');

  String get supportDevelopmentTitle => choose(
    '¿Te gusta la app? Apoya su desarrollo ❤️',
    'Enjoying the app? Support its development ❤️',
  );
  String get supportDevelopmentBody => choose(
    'La app seguirá siendo gratuita. Si te resulta útil, puedes hacer una contribución para ayudarme a mantenerla y seguir agregando funciones.',
    'The app will remain free. If you find it useful, you can make a contribution to help me maintain it and continue adding features.',
  );
  String get supportDevelopmentAction => choose('Apoyar', 'Support');
  String get supportDevelopmentOpenFailed => choose(
    'No se pudo abrir la página de apoyo.',
    'The support page could not be opened.',
  );

  String songCount(int count) {
    if (isEnglish) {
      return '$count ${count == 1 ? 'song' : 'songs'}';
    }
    return '$count ${count == 1 ? 'cancion' : 'canciones'}';
  }

  String songCountWithDuration(int count, Duration? duration) {
    final countText = songCount(count);
    if (duration == null) {
      return countText;
    }
    return '$countText · ${formatCollectionDuration(duration)}';
  }

  String playbackQueueSummary(int count) {
    if (isEnglish) {
      return 'Playback Queue - $count ${count == 1 ? 'Song' : 'Songs'}';
    }
    return 'Cola de Reproducción - $count '
        '${count == 1 ? 'Canción' : 'Canciones'}';
  }

  String liveQueueSummary(int total, int ready, int pending) {
    if (isEnglish) {
      return '$total requests - $ready ready - $pending pending';
    }
    return '$total pedidos - $ready listos - $pending pendientes';
  }

  String exitPressesRemaining(int remaining) {
    if (isEnglish) {
      return 'Press ${remaining == 1 ? 'once' : '$remaining more times'} to exit.';
    }
    return 'Presiona $remaining ${remaining == 1 ? 'vez' : 'veces'} mas para salir.';
  }

  String downloadLabel(String label, String title, int queuedCount) {
    if (queuedCount <= 0) {
      return '$label: $title';
    }
    final queuedText = isEnglish
        ? '$queuedCount queued'
        : '$queuedCount en cola';
    return '$label: $title - $queuedText';
  }
}
