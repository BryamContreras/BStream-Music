import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/lyrics_romanization_language.dart';
import 'lyrics_animation_style.dart';
import 'mini_player_background_mode.dart';
import 'mini_player_mode.dart';

enum AppLanguage { spanish, english }

extension AppLanguageLabel on AppLanguage {
  String get label => switch (this) {
    AppLanguage.spanish => 'Español',
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
  String homeGreeting({required int hour, String? firstName}) {
    assert(hour >= 0 && hour < 24);
    final normalized = firstName?.trim();
    final greeting = hour < 12
        ? choose('Buenos días', 'Good morning')
        : choose('Buenas tardes', 'Good afternoon');
    if (normalized == null || normalized.isEmpty) {
      return greeting;
    }
    return '$greeting, $normalized';
  }

  String get refreshHomeRecommendations =>
      choose('Refrescar recomendaciones', 'Refresh recommendations');
  String get refreshingHomeRecommendations =>
      choose('Refrescando recomendaciones', 'Refreshing recommendations');
  String get popularArtists => choose('Artistas populares', 'Popular artists');
  String get recommendedArtists =>
      choose('Artistas recomendados', 'Recommended artists');
  String get goToArtist => choose('Ir al artista', 'Go to artist');
  String get goToAlbum => choose('Ir al álbum', 'Go to album');
  String get albumNavigationUnavailable => choose(
    'No se pudo encontrar el álbum de esta canción.',
    'The album for this song could not be found.',
  );
  String get artistProfile => choose('Perfil del artista', 'Artist profile');
  String get popularSongs => choose('Canciones más populares', 'Popular songs');
  String get albums => choose('Álbumes', 'Albums');
  String get singles => choose('Sencillos', 'Singles');
  String get artistMix => 'Mix';
  String get subscribe => choose('Suscribirse', 'Subscribe');
  String get unsubscribe => choose('Cancelar suscripción', 'Unsubscribe');
  String get artistProfileLoadError => choose(
    'No se pudo cargar el perfil del artista.',
    'The artist profile could not be loaded.',
  );
  String get artistMixLoadError => choose(
    'No se pudo iniciar el mix del artista.',
    'The artist mix could not be started.',
  );
  String get artistSubscriptionFailed => choose(
    'No se pudo actualizar la suscripción.',
    'The subscription could not be updated.',
  );
  String get artistSubscriptionUnavailable => choose(
    'Este artista no tiene una suscripción disponible.',
    'A subscription is not available for this artist.',
  );
  String get signInToSubscribe =>
      choose('Inicia sesión para suscribirte', 'Sign in to subscribe');
  String get youtubeMusicAccount =>
      choose('Cuenta de YouTube Music', 'YouTube Music account');
  String get youtubeMusic => choose('YouTube Music', 'YouTube Music');
  String get signInToYouTubeMusic =>
      choose('Iniciar sesión en YouTube Music', 'Sign in to YouTube Music');
  String get youtubeMusicUnofficialTitle =>
      choose('Integración no oficial', 'Unofficial integration');
  String get youtubeMusicUnofficialDisclosure => choose(
    'La integración con YouTube Music utiliza interfaces no oficiales y no '
        'está afiliada con Google. BStream no guarda tu contraseña. YouTube '
        'puede cambiar, bloquear o restringir esta función.',
    'The YouTube Music integration uses unofficial interfaces and is not '
        'affiliated with Google. BStream never stores your password. YouTube '
        'may change, block, or restrict this feature.',
  );
  String get understandAndContinue =>
      choose('Entiendo y continuar', 'I understand, continue');
  String get syncNow => choose('Sincronizar ahora', 'Sync now');
  String get playlistSyncConsentTitle =>
      choose('Sincronizar playlists', 'Synchronize playlists');
  String playlistSyncConsentBody(int? localPlaylistCount) {
    final localPreservation = localPlaylistCount == null
        ? choose(
            'Tus playlists locales se conservarán',
            'Your local playlists will stay',
          )
        : choose(
            localPlaylistCount == 1
                ? 'Tu playlist local se conservará'
                : 'Tus $localPlaylistCount playlists locales se conservarán',
            localPlaylistCount == 1
                ? 'Your local playlist will stay'
                : 'Your $localPlaylistCount local playlists will stay',
          );
    return choose(
      '$localPreservation en BStream. Favoritos se vinculará con "Me gusta" '
          'de YouTube Music; las playlists locales aún no vinculadas se crearán '
          'como privadas y las remotas se importarán aquí. Esta primera '
          'sincronización no elimina tus playlists locales.',
      '$localPreservation in BStream. Favorites will sync with YouTube Music '
          'Liked Music; unlinked local playlists are created as private playlists '
          'and remote playlists are imported here. This first sync does not '
          'delete your local playlists.',
    );
  }

  String get keepAndSync =>
      choose('Conservar y sincronizar', 'Keep and synchronize');
  String get notNow => choose('Ahora no', 'Not now');
  String get playlistSyncConsentSaveFailed => choose(
    'No se pudo guardar tu decisión. No se inició la sincronización.',
    'Your decision could not be saved. Synchronization was not started.',
  );
  String get syncingPlaylists =>
      choose('Sincronizando playlists…', 'Syncing playlists…');
  String get playlistsSynchronized =>
      choose('Playlists sincronizadas', 'Playlists synchronized');
  String playlistsImported(int count) => choose(
    count == 1
        ? 'Se importó 1 playlist de YouTube Music.'
        : 'Se importaron $count playlists de YouTube Music.',
    count == 1
        ? 'Imported 1 playlist from YouTube Music.'
        : 'Imported $count playlists from YouTube Music.',
  );
  String get resolvePlaylistSyncConflicts =>
      choose('Resolver conflictos', 'Resolve conflicts');
  String get playlistSyncConflictWarning => choose(
    'BStream detuvo estas playlists para no repetir ni sobrescribir cambios '
        'inciertos. Elige qué versión conservar en cada una.',
    'BStream paused these playlists to avoid repeating or overwriting '
        'uncertain changes. Choose which version to keep for each one.',
  );
  String get keepBStreamPlaylist => choose('Conservar BStream', 'Keep BStream');
  String get keepYouTubeMusicPlaylist =>
      choose('Conservar YouTube Music', 'Keep YouTube Music');
  String get noPlaylistSyncConflicts => choose(
    'No hay conflictos de playlists pendientes.',
    'There are no unresolved playlist conflicts.',
  );
  String get playlistConflictResolveFailed => choose(
    'No se pudo cerrar el conflicto. La playlist permanece detenida para '
        'evitar repetir una escritura incierta.',
    'The conflict could not be closed. The playlist remains paused to avoid '
        'repeating an uncertain write.',
  );
  String get switchYouTubeChannel => choose('Cambiar canal', 'Switch channel');
  String get disconnectYouTubeMusic =>
      choose('Desconectar YouTube Music', 'Disconnect YouTube Music');
  String get youtubeMusicLoginBlocked => choose(
    'Google bloqueó el inicio de sesión dentro de la app. Por seguridad, '
        'BStream no puede copiar la sesión de tu navegador. Puedes seguir '
        'usando la app sin cuenta.',
    'Google blocked sign-in inside the app. For security, BStream cannot copy '
        'the session from your browser. You can keep using the app without an '
        'account.',
  );
  String get continueListening =>
      choose('Seguir escuchando', 'Continue listening');
  String becauseYouListened(String? seedTitle) {
    final normalized = seedTitle?.trim();
    if (normalized == null || normalized.isEmpty) {
      return choose('Porque escuchaste…', 'Because you listened…');
    }
    return choose(
      'Porque escuchaste $normalized',
      'Because you listened to $normalized',
    );
  }

  String get yourMixes => choose('Tus mixes', 'Your mixes');
  String get newForYou => choose('Nuevos para ti', 'New for you');
  String get discovery => choose('Descubrimiento', 'Discovery');
  String get recentlyPlayed =>
      choose('Escuchado recientemente', 'Recently played');
  String get myPlaylists => choose('Mis playlists', 'My playlists');
  String get mix => 'Mix';
  String get homeCollectionLoadError => choose(
    'No se pudo cargar esta selección.',
    'This selection could not be loaded.',
  );
  String get homeCollectionEmpty => choose(
    'Esta selección no tiene canciones disponibles.',
    'This selection has no available songs.',
  );
  String get noRecentSongs => choose(
    'Aún no has escuchado canciones.',
    'No recently played songs yet.',
  );
  String get search => choose('Buscar', 'Search');
  String get clearSearch => choose('Limpiar búsqueda', 'Clear search');
  String get searchTitle => choose('Búsqueda', 'Search');
  String get player => choose('Reproductor', 'Player');
  String get localTab => 'Local';
  String get localMusic => choose('Música local', 'Local music');
  String get allLocalSongs => choose('Todas las canciones', 'All songs');
  String get localMusicFolders => choose('Carpetas', 'Folders');
  String get localMusicEmptyTitle =>
      choose('No encontramos música local', 'No local music found');
  String get localMusicEmptyBody => choose(
    'Agrega archivos de audio al dispositivo o revisa los filtros de almacenamiento.',
    'Add audio files to the device or review the storage filters.',
  );
  String get localMusicPermissionTitle =>
      choose('Permite el acceso a tu música', 'Allow access to your music');
  String get localMusicPermissionBody => choose(
    'BStream necesita permiso para mostrar y reproducir los archivos de audio del dispositivo.',
    'BStream needs permission to show and play audio files on this device.',
  );
  String get allowMusicAccess => choose('Permitir acceso', 'Allow access');
  String get localMusicLoadError => choose(
    'No se pudo leer la música del dispositivo.',
    'Device music could not be read.',
  );
  String get playAll => choose('Reproducir todo', 'Play all');
  String get refresh => choose('Actualizar', 'Refresh');
  String get library => choose('Biblioteca', 'Library');
  String get settings => choose('Ajustes', 'Settings');
  String get searchHint =>
      choose('Canción, artista o álbum', 'Song, artist, or album');
  String get searchEmptyTitle => choose(
    'Busca canciones, artistas o enlaces',
    'Search songs, artists, or links',
  );
  String get searchEmptySubtitle =>
      choose('Los resultados aparecerán aquí.', 'Results will appear here.');
  String get searchErrorTitle => choose('No se pudo buscar', 'Search failed');
  String get searchSongs => choose('Canciones', 'Songs');
  String get searchVideos => choose('Videos', 'Videos');
  String get searchAlbums => choose('Álbumes', 'Albums');
  String get searchArtists => choose('Artistas', 'Artists');
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
  String get searchArtistsEmpty => choose(
    'No encontramos artistas para esta búsqueda.',
    'No artists matched this search.',
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
  String get noPlayback => choose('Sin reproducción', 'Nothing playing');
  String get nowPlaying => choose('En reproducción', 'Now playing');
  String get noTitle => choose('Sin título', 'Untitled');
  String get unknownArtist => choose('Desconocido', 'Unknown');
  String get playbackError => choose('Error de reproducción', 'Playback error');
  String get externalAudioFolderUnavailable => choose(
    'Se reproducirá el audio elegido, pero Android no permitió cargar el resto de la carpeta.',
    'The selected audio will play, but Android did not allow the rest of the folder to be loaded.',
  );
  String get volume => choose('Volumen', 'Volume');
  String get volumeControl => choose('Control de Volumen', 'Volume control');
  String get lyrics => choose('Letras', 'Lyrics');
  String get lyricsLoading =>
      choose('Buscando la letra...', 'Finding lyrics...');
  String get lyricsNotFound => choose(
    'No encontramos una letra para esta canción.',
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
      choose('Buscar por otro título', 'Search by another title');
  String get manualLyricsSearchAction =>
      choose('Buscar letras', 'Search lyrics');
  String get syncedLyricsLabel => choose('Sincronizada', 'Synchronized');
  String get plainLyricsLabel => choose('Sin sincronizar', 'Not synchronized');
  String get backToLyrics => choose('Volver', 'Back');
  String get lyricsNoInternet =>
      choose('No hay conexión a Internet.', 'No Internet connection.');
  String get lyricsInstrumental => choose(
    'Esta canción aparece como instrumental.',
    'This track is marked as instrumental.',
  );
  String get lyricsUnsynced => choose(
    'Esta letra no incluye tiempos sincronizados.',
    'These lyrics do not include synchronized timing.',
  );
  String get lyricsOffset => choose('Desfase', 'Offset');
  String get lyricsOffsetHint => choose(
    'Ajústalo si la letra aparece antes o después de la voz.',
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
      choose('Apariencia de letras', 'Lyrics appearance');
  String get lyricsAppearanceSummary => choose(
    'Personaliza la animación, alineación y romanización.',
    'Customize lyrics animation, alignment, and romanization.',
  );
  String get lyricsAnimation => choose('Animación', 'Animation');
  String get lyricsAnimationSmooth => choose('Suave', 'Smooth');
  String get lyricsAnimationSlide => choose('Deslizar', 'Slide');
  String get lyricsAnimationHighlight => choose('Resaltar', 'Highlight');
  String get lyricsRomanization => choose('Romanización', 'Romanization');
  String get romanizeLyrics => choose('Romanizar letras', 'Romanize lyrics');
  String get romanizeLyricsSummary => choose(
    'Convierte los idiomas seleccionados al alfabeto latino.',
    'Convert the selected languages to the Latin alphabet.',
  );
  String get romanizationLanguages =>
      choose('Idiomas para romanizar', 'Languages to romanize');
  String romanizationLanguageLabel(LyricsRomanizationLanguage language) =>
      switch (language) {
        LyricsRomanizationLanguage.japanese => choose('Japonés', 'Japanese'),
        LyricsRomanizationLanguage.korean => choose('Coreano', 'Korean'),
        LyricsRomanizationLanguage.chinese => choose('Chino', 'Chinese'),
        LyricsRomanizationLanguage.cyrillic => choose('Cirílico', 'Cyrillic'),
        LyricsRomanizationLanguage.arabic => choose('Árabe', 'Arabic'),
        LyricsRomanizationLanguage.hebrew => choose('Hebreo', 'Hebrew'),
      };
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
  };
  String get retry => choose('Reintentar', 'Retry');
  String get lyricsSource =>
      choose('Letras proporcionadas por LRCLIB', 'Lyrics provided by LRCLIB');
  String get tapLyricsToSeek => choose(
    'Toca una línea para ir a ese momento.',
    'Tap a line to seek to that moment.',
  );
  String get close => choose('Cerrar', 'Close');
  String get moreOptions => choose('Más opciones', 'More options');
  String get shareSong => choose('Compartir canción', 'Share song');
  String get shareSongTitle => shareSong;
  String shareSongMessage(String title, String artist) =>
      choose('Escucha "$title" de $artist.', 'Listen to "$title" by $artist.');
  String get shareFailed => choose(
    'No se pudo compartir la canción.',
    'The song could not be shared.',
  );
  String get sharedSong => choose('Canción compartida', 'Shared song');
  String get addToPlaylist => choose('Añadir a playlist', 'Add to playlist');
  String get favorites => choose('Favoritos', 'Favorites');
  String get addToFavorites => choose('Añadir a favoritos', 'Add to favorites');
  String get removeFromFavorites =>
      choose('Quitar de favoritos', 'Remove from favorites');
  String get addedToFavorites =>
      choose('Canción agregada a favoritos.', 'Song added to favorites.');
  String get removedFromFavorites =>
      choose('Canción quitada de favoritos.', 'Song removed from favorites.');
  String get choosePlaylist => choose('Elegir playlist', 'Choose playlist');
  String selectedSongs(int count) => choose(
    count == 1 ? '1 canción seleccionada' : '$count canciones seleccionadas',
    count == 1 ? '1 song selected' : '$count songs selected',
  );
  String songsAddedToPlaylist(int count) => choose(
    count == 1
        ? 'Canción agregada a la playlist.'
        : '$count canciones agregadas a la playlist.',
    count == 1 ? 'Song added to playlist.' : '$count songs added to playlist.',
  );
  String get songsAlreadyInPlaylist => choose(
    'Las canciones seleccionadas ya están en esa playlist.',
    'The selected songs are already in that playlist.',
  );
  String get createPlaylistFirst =>
      choose('Crea una playlist primero.', 'Create a playlist first.');
  String get songAddedToPlaylist =>
      choose('Canción agregada a la playlist.', 'Song added to playlist.');
  String get downloadQueued =>
      choose('Descarga agregada a la cola.', 'Download added to queue.');
  String get back => choose('Volver', 'Back');
  String get error => choose('Error', 'Error');
  String get downloads => choose('Descargas', 'Downloads');
  String get downloadedSongs =>
      choose('Canciones descargadas', 'Downloaded songs');
  String get streamOnlySong => choose(
    'No descargada; requiere conexión',
    'Not downloaded; connection required',
  );
  String get liveQueue => choose('LIVE', 'LIVE');
  String get liveQueueTitle => choose('Cola LIVE', 'LIVE queue');
  String get playbackQueue => choose('Cola de reproducción', 'Playback queue');
  String get playbackQueueEmpty => choose(
    'No hay canciones en la cola actual.',
    'There are no songs in the current queue.',
  );
  String get liveQueueEmpty => choose(
    'Los pedidos !play aparecerán aquí.',
    'Live !play requests will appear here.',
  );
  String get clearLiveQueue => choose('Limpiar cola LIVE', 'Clear LIVE queue');
  String get requestedBy => choose('Pedido por', 'Requested by');
  String get moderator => choose('Moderador', 'Moderator');
  String get commandPermissions =>
      choose('Quién puede usar los comandos', 'Who can use commands');
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
    'Todavía no hay playlists locales.',
    'There are no local playlists yet.',
  );
  String get playlistMissing =>
      choose('La playlist ya no existe.', 'This playlist no longer exists.');
  String get deleteSong => choose('Eliminar canción', 'Delete song');
  String get deleteSelectedSongs =>
      choose('Eliminar canciones', 'Delete songs');
  String confirmDeleteSongs(int count) => choose(
    count == 1
        ? 'Se eliminará la canción descargada y su archivo.'
        : 'Se eliminarán $count canciones descargadas y sus archivos.',
    count == 1
        ? 'The downloaded song and its file will be deleted.'
        : '$count downloaded songs and their files will be deleted.',
  );
  String songsDeleted(int count) => choose(
    count == 1 ? 'Canción eliminada.' : '$count canciones eliminadas.',
    count == 1 ? 'Song deleted.' : '$count songs deleted.',
  );
  String get delete => choose('Eliminar', 'Delete');
  String get rename => choose('Renombrar', 'Rename');
  String get renameSong => choose('Renombrar canción', 'Rename song');
  String get renamePlaylist => choose('Renombrar playlist', 'Rename playlist');
  String get deletePlaylist => choose('Eliminar playlist', 'Delete playlist');
  String get songRenamed => choose('Canción renombrada.', 'Song renamed.');
  String get playlistRenamed =>
      choose('Playlist renombrada.', 'Playlist renamed.');
  String get playlistDeleted =>
      choose('Playlist eliminada.', 'Playlist deleted.');
  String get removePlaylistFromBStream =>
      choose('Quitar sólo de BStream', 'Remove only from BStream');
  String get deletePlaylistFromYouTubeMusic => choose(
    'Eliminar también de YouTube Music',
    'Also delete from YouTube Music',
  );
  String get confirmDeleteSyncedPlaylist => choose(
    'Esta playlist está sincronizada con YouTube Music. Puedes quitarla sólo '
        'de BStream o eliminar también la playlist de tu cuenta. Las canciones '
        'descargadas no se borrarán.',
    'This playlist is synced with YouTube Music. You can remove it only from '
        'BStream or also delete the playlist from your account. Downloaded '
        'songs will not be deleted.',
  );
  String get confirmDeleteReadOnlySyncedPlaylist => choose(
    'Esta playlist está vinculada con YouTube Music, pero la cuenta activa no '
        'puede eliminarla allí. Sólo se quitará de BStream y no se volverá a '
        'importar automáticamente.',
    'This playlist is linked to YouTube Music, but the active account cannot '
        'delete it there. It will only be removed from BStream and will not be '
        'imported automatically again.',
  );
  String get youtubeMusicPlaylistDeletionScheduled => choose(
    'La playlist se quitó de BStream. Su eliminación en YouTube Music quedó '
        'programada para la próxima sincronización.',
    'The playlist was removed from BStream. Its YouTube Music deletion is '
        'scheduled for the next sync.',
  );
  String get confirmDeletePlaylist => choose(
    'Esta acción no elimina las canciones guardadas.',
    'This does not delete downloaded songs.',
  );
  String get songDeleted => choose('Canción eliminada.', 'Song deleted.');
  String get removeFromPlaylist =>
      choose('Quitar de playlist', 'Remove from playlist');
  String removeSelectedSongs(int count, {required bool favorites}) => choose(
    favorites
        ? (count == 1
              ? 'Quitar la canción de Favoritos?'
              : 'Quitar $count canciones de Favoritos?')
        : (count == 1
              ? 'Quitar la canción de esta playlist?'
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
                  ? 'Canción quitada de Favoritos.'
                  : '$count canciones quitadas de Favoritos.')
            : (count == 1
                  ? 'Canción quitada de la playlist.'
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
        'Se omitirán $invalid filas inválidas y se combinarán $duplicates '
        'filas repetidas. '
        'Las canciones existentes se reutilizarán; las faltantes se '
        'descargarán en paralelo con un límite seguro.',
    '$tracks songs and $playlists playlists were found. $invalid invalid '
        'rows will be skipped and $duplicates repeated rows will be merged. '
        'Existing songs '
        'will be reused; missing songs will be downloaded in parallel with a '
        'safe limit.',
  );
  String get csvImportDataNotice => choose(
    'La descarga puede consumir datos y almacenamiento. Puedes detener la '
        'importación después de las descargas activas.',
    'Downloads may use data and storage. You can stop the import after the '
        'active downloads finish.',
  );
  String get importAndDownload =>
      choose('Importar y descargar', 'Import and download');
  String get csvImporting =>
      choose('Importando biblioteca', 'Importing library');
  String csvImportProgress(int processed, int total) =>
      choose('$processed de $total canciones', '$processed of $total songs');
  String get stopAfterCurrent =>
      choose('Detener después de las activas', 'Stop after active downloads');
  String get csvStopRequested => choose(
    'Se detendrá al terminar las descargas activas.',
    'The import will stop after the active downloads finish.',
  );
  String get csvImportCompleted =>
      choose('Importación terminada', 'Import complete');
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
    'La importación se detuvo. Los elementos completados se conservaron.',
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
  String get csvProfileBStream => 'BStream Music';
  String get csvProfileMetroList => 'MetroList';
  String get csvProfileHarmony => 'Harmony / RiMusic';
  String get csvProfileSoundiiz => 'Soundiiz';
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
      choose('Operación cancelada.', 'Operation cancelled.');
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
  String get surfaceEffects =>
      choose('Efectos de superficie', 'Surface effects');
  String get surfaceBackground =>
      choose('Fondo de las superficies', 'Surface background');
  String get surfaceBackgroundAccent => choose('Acento', 'Accent');
  String get surfaceBackgroundTransparent =>
      choose('Transparente', 'Transparent');
  String get miniPlayer => choose('Mini reproductor', 'Mini player');
  String get miniPlayerStyle => choose('Estilo', 'Style');
  String get miniPlayerClassic => choose('Clásico', 'Classic');
  String get miniPlayerCapsule => choose('Cápsula', 'Capsule');
  String get miniPlayerBackground =>
      choose('Fondo del Mini reproductor', 'Mini player background');
  String get miniPlayerBackgroundAccent => choose('Acento', 'Accent');
  String get miniPlayerBackgroundArtwork => choose('Portada', 'Artwork');
  String get miniPlayerBackgroundTransparent =>
      choose('Transparente', 'Transparent');
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
  String get spanish => choose('Español', 'Spanish');
  String get english => 'English';
  String get playback => choose('Reproducción', 'Playback');
  String get album => choose('Álbum', 'Album');
  String get privacyAndRecommendations =>
      choose('Privacidad y recomendaciones', 'Privacy and recommendations');
  String get recommendationHistory =>
      choose('Historial de recomendaciones', 'Recommendation history');
  String get recommendationHistoryEnabled => choose(
    'BStream aprende de las canciones que escuchas para personalizar Inicio.',
    'BStream learns from the songs you listen to in order to personalize Home.',
  );
  String get recommendationHistoryDisabled => choose(
    'Las nuevas reproducciones no se usarán para personalizar Inicio.',
    'New plays will not be used to personalize Home.',
  );
  String get clearRecommendationHistory => choose(
    'Borrar historial y recomendaciones',
    'Clear history and recommendations',
  );
  String get clearRecommendationHistorySummary => choose(
    'Elimina las señales locales y la caché personalizada sin borrar descargas, favoritos ni playlists.',
    'Deletes local signals and the personalized cache without removing downloads, favorites, or playlists.',
  );
  String get clearRecommendationHistoryTitle => choose(
    '¿Borrar historial y recomendaciones?',
    'Clear history and recommendations?',
  );
  String get clearRecommendationHistoryMessage => choose(
    'BStream olvidará lo aprendido de tus escuchas. Tus descargas, favoritos y playlists permanecerán intactos.',
    'BStream will forget what it learned from your listening. Downloads, favorites, and playlists will remain intact.',
  );
  String get recommendationHistoryCleared => choose(
    'Historial y recomendaciones eliminados.',
    'History and recommendations cleared.',
  );
  String get sleepTimer => choose('Temporizador', 'Sleep timer');
  String get storage => choose('Almacenamiento', 'Storage');
  String get localMusicFilters =>
      choose('Filtros de música local', 'Local music filters');
  String localMusicFiltersSummary(int activeCount) => choose(
    activeCount == 0
        ? 'Sin filtros activos'
        : activeCount == 1
        ? '1 filtro activo'
        : '$activeCount filtros activos',
    activeCount == 0
        ? 'No active filters'
        : activeCount == 1
        ? '1 active filter'
        : '$activeCount active filters',
  );
  String get hideWhatsAppAudio =>
      choose('Ocultar audios de WhatsApp', 'Hide WhatsApp audio');
  String get hideWhatsAppAudioSummary => choose(
    'No muestra notas de voz ni audios guardados en carpetas de WhatsApp.',
    'Hide voice notes and audio stored in WhatsApp folders.',
  );
  String get hideTelegramAudio =>
      choose('Ocultar audios de Telegram', 'Hide Telegram audio');
  String get hideTelegramAudioSummary => choose(
    'No muestra notas de voz ni audios guardados en carpetas de Telegram.',
    'Hide voice notes and audio stored in Telegram folders.',
  );
  String get hideAudioRecordings =>
      choose('Ocultar grabaciones de audio', 'Hide audio recordings');
  String get hideAudioRecordingsSummary => choose(
    'No muestra archivos guardados por grabadoras de voz y llamadas.',
    'Hide files saved by voice and call recorder apps.',
  );
  String get hideTracksUnder30Seconds => choose(
    'Ocultar canciones de menos de 30 segundos',
    'Hide songs shorter than 30 seconds',
  );
  String get hideTracksUnder30SecondsSummary => choose(
    'Evita tonos, grabaciones cortas y otros audios breves.',
    'Avoid ringtones, short recordings, and other brief audio.',
  );
  String get backupAndRestore =>
      choose('Respaldo y Restauración', 'Backup and restore');
  String get storageSummary => choose(
    'Exporta o restaura tu biblioteca y configuración.',
    'Export or restore your library and settings.',
  );
  String get integrations => choose('Integraciones', 'Integrations');
  String get automaticShutdown =>
      choose('Apagado automático', 'Automatic shutdown');
  String get sleepTimerOff => choose('Desactivado', 'Off');
  String get crossfade => 'Crossfade';
  String get crossfadeSummary => choose(
    'Superpone suavemente el final de una canción con el inicio de la siguiente.',
    'Smoothly overlaps the end of one song with the start of the next.',
  );
  String get crossfadeDuration =>
      choose('Duración del crossfade', 'Crossfade duration');
  String secondsShort(int seconds) => '$seconds s';
  String get customDuration => choose('Personalizar', 'Custom');
  String get apply => choose('Aplicar', 'Apply');
  String get timerDuration =>
      choose('Duración del temporizador', 'Timer duration');
  String get startTimer => choose('Iniciar', 'Start');
  String get invalidTimerDuration => choose(
    'Ingresa una duración entre 1 y 720 minutos.',
    'Enter a duration between 1 and 720 minutes.',
  );
  String get desktopTools => choose('Herramientas desktop', 'Desktop tools');
  String get liveConnection => choose('Conexión LIVE', 'LIVE connection');
  String get liveConnectionSummary => choose(
    'Conecta un LIVE y configura quién puede pedir canciones.',
    'Connect a LIVE and choose who can request songs.',
  );
  String get liveUnavailable => choose(
    'Conexión LIVE no disponible en este dispositivo.',
    'LIVE connection is not available on this device.',
  );
  String get backupSummary => choose(
    'Exporta o restaura tu biblioteca y configuración.',
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
      choose('Lista para reproducción remota', 'Ready for remote playback');
  String get connect => choose('Conectar', 'Connect');
  String get disconnect => choose('Desconectar', 'Disconnect');
  String get connected => choose('conectado', 'connected');
  String get disconnected => choose('desconectado', 'disconnected');
  String get lastCommand => choose('Último comando', 'Last command');
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
  String miniPlayerModeLabel(MiniPlayerMode mode) => switch (mode) {
    MiniPlayerMode.standard => miniPlayerClassic,
    MiniPlayerMode.capsule => miniPlayerCapsule,
  };
  String surfaceBackgroundModeLabel(SurfaceBackgroundMode mode) =>
      switch (mode) {
        SurfaceBackgroundMode.accent => surfaceBackgroundAccent,
        SurfaceBackgroundMode.transparent => surfaceBackgroundTransparent,
      };
  String miniPlayerBackgroundModeLabel(MiniPlayerBackgroundMode mode) =>
      switch (mode) {
        MiniPlayerBackgroundMode.accent => miniPlayerBackgroundAccent,
        MiniPlayerBackgroundMode.artwork => miniPlayerBackgroundArtwork,
        MiniPlayerBackgroundMode.transparent => miniPlayerBackgroundTransparent,
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
      'El reproductor se detendrá en $formatted',
      'The player will stop in $formatted',
    );
  }

  String timerMinutes(int minutes) => choose('$minutes min', '$minutes min');

  String get applicationInformation =>
      choose('Información de la aplicación', 'Application information');
  String get aboutApplication =>
      choose('Acerca de la aplicación', 'About the app');
  String get aboutApplicationSummary => choose(
    'Versión, apoyo y repositorio',
    'Version, support, and repository',
  );
  String get versionLabel => choose('Versión', 'Version');

  String get supportDevelopmentTitle =>
      choose('Apoyar el desarrollo', 'Support development');
  String get supportDevelopmentBody => choose(
    'Ayuda a mantener BStream Music y a seguir agregando funciones.',
    'Help maintain BStream Music and keep adding features.',
  );
  String get supportDevelopmentOpenFailed => choose(
    'No se pudo abrir la página de apoyo.',
    'The support page could not be opened.',
  );
  String get githubRepositoryTitle =>
      choose('Repositorio de GitHub', 'GitHub repository');
  String get githubRepositoryBody =>
      choose('Código fuente y contribuciones', 'Source code and contributions');
  String get githubRepositoryOpenFailed => choose(
    'No se pudo abrir el repositorio de GitHub.',
    'The GitHub repository could not be opened.',
  );

  String songCount(int count) {
    if (isEnglish) {
      return '$count ${count == 1 ? 'song' : 'songs'}';
    }
    return '$count ${count == 1 ? 'canción' : 'canciones'}';
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
    return 'Presiona $remaining ${remaining == 1 ? 'vez' : 'veces'} más para salir.';
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
